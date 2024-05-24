//
//  ParsecWeb.swift
//  OpenParsec
//
//  Created by s s on 2024/5/17.
//

import Foundation
import ParsecSDK
import WebRTC
import VideoDecoder
import GLKit
import Opus

class ParsecWebBuffer {
	var decodedVideoBuffer = Queue<CMSampleBuffer>(maxLength: 5)
	var decodedAudioBuffer = Queue<AVAudioPCMBuffer>(maxLength: 5)
	var controlBuffer : Data?
	var parsecStatus: ParsecStatus = ParsecStatus(20)
	var exStatus: ParsecClientStatus = ParsecClientStatus()
}

class VideoChannelDelegate: NSObject, RTCDataChannelDelegate {
	var videoStream = VideoStream()
	let decoder : VideoDecoder
	
	var isFirst = true
	
	private let size = CGSize(width: 1920, height: 1080)
	
	init(decoder: VideoDecoder) {
		self.decoder = decoder
	}
	
	func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
		print("video channel State Changed! \(dataChannel.readyState)")
	}
	
	func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
		// 拿到的data不一定是一个buffer一个NALU,要对buffer进行拆分
		// 拿到直接decode,解码器的delegate会把结果放在缓存里等opengl来拿
		
		let nalus = videoStream.pushAndGetNalu(buffer.data)
		for nalu in nalus {
			let vp = VideoPacket(nalu, bufferSize: nalu.count, fps: 60, type: .h264, videoSize: size)
			decoder.decodeOnePacket(vp)
		}
		
	}
	
}

class ControlChannelDelegate: NSObject, RTCDataChannelDelegate {
	let buffer: ParsecWebBuffer
	init(buffer: ParsecWebBuffer) {
		self.buffer = buffer
	}
	
	func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
		// 控制通道切换为open后要发送一个控制消息,这样host才会开始发送数据
		if (dataChannel.readyState != .open) {
			return
		}
		let data = ParsecWebDataParser.getResolutionByte(1920, 1080)
		dataChannel.sendData(RTCDataBuffer.init(data: data, isBinary: true))
		buffer.parsecStatus = ParsecStatus(0)
	}
	
	func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
//		print("control channel received data!")
		let status = buffer.data
		status.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
			let ptr2 = ptr.baseAddress
			let type = ptr2?.load(fromByteOffset: 12, as: UInt8.self)
			let p1 = ptr2?.load(fromByteOffset: 0, as: UInt8.self).byteSwapped
			let p2 = ptr2?.load(fromByteOffset: 4, as: UInt32.self).byteSwapped
			let p3 = ptr2?.load(fromByteOffset: 8, as: UInt32.self).byteSwapped

			
			switch type {
			case 21:
				self.buffer.exStatus.`self`.metrics.0.encodeLatency = Float(p2!) / 1000
				break
			default:
				print("Got control msg type: \(type!)")
			}
			
			
		}

	}
	
}
//MARK: Audio Delegate
class AudioChannelDelegate: NSObject, RTCDataChannelDelegate {
	let buffer: ParsecWebBuffer
	let decoder = OpusDecoder(sampleRate: 48000, channels: 2)
	let player: AudioPlayer
	var t = 1
	
	init(player: AudioPlayer, buffer: ParsecWebBuffer) {
		self.buffer = buffer
		self.player = player
	}
	
	func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
		print("Audio channel State Changed! \(dataChannel.readyState)")
	}
	
	func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
		let frame = buffer.data
		frame.withUnsafeBytes{ (ptr : UnsafeRawBufferPointer) in
			let ptr2 = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self)
			let decodedFrame = (try! decoder.decode(ptr2, packetSize: frame.count, frameSize: 960))
			self.player.play(buffer: decodedFrame)
			
		}
	}
	
}

class DecoderDelegate : VideoDecoderDelegate {
	private var buffer: ParsecWebBuffer
	private var lastOutputTime: Double = -1
	
	init(buffer: ParsecWebBuffer) {
		self.buffer = buffer
	}
	
	func decodeOutput(video: CMSampleBuffer) {
		buffer.decodedVideoBuffer.enqueue(video)
		let timeNow = CFAbsoluteTimeGetCurrent() * 1000
		if lastOutputTime != -1 {
			self.buffer.exStatus.`self`.metrics.0.decodeLatency = Float(timeNow - lastOutputTime)
		}
		lastOutputTime = timeNow
		if let size = video.image?.size {
			buffer.exStatus.decoder.0.height = UInt32(size.height)
			buffer.exStatus.decoder.0.width = UInt32(size.width)
		}
		
	}
	
	func decodeOutput(error: DecodeError) {
		print("error!\(error)")
	}
	
	
}

class ParsecWeb : ParsecService, WebSocketDelegate, WebRTCClientDelegate{
	
	public var hostWidth:Float = 0
	public var hostHeight:Float = 0
	
	public var netProtocol:Int32 = 1
	public var mediaContainer:Int32 = 0
	public var pngCursor:Bool = false
	private var remoteUfrag: String = ""
	
	public var mouseInfo = MouseInfo()
	
	private let client: WebRTCClient
	private let ws = WebSocket()
	
	public let buffer: ParsecWebBuffer
	private let videoChannelDelegate:VideoChannelDelegate
	private let controlChannelDelegate:ControlChannelDelegate
	private let audioChannelDelegate:AudioChannelDelegate
	private var attemptId = ""
	private var peerId = ""
	
	private let size = CGSize(width: 1920, height: 1080)
	
	private let videoDecoder : H264Decoder
	private var lastFrame : CMSampleBuffer?
	private let player: AudioPlayer
	
	private var statusTimer: Timer?
	
	init() {
		client = WebRTCClient(iceServers: ["stun:stun.parsec.gg:3478"])
		self.buffer = ParsecWebBuffer()
		videoDecoder = H264Decoder(delegate: DecoderDelegate(buffer: self.buffer))
		self.videoChannelDelegate = VideoChannelDelegate(decoder: videoDecoder)
		self.controlChannelDelegate = ControlChannelDelegate(buffer: buffer)
		self.player = AudioPlayer()
		self.audioChannelDelegate = AudioChannelDelegate(player: player, buffer: buffer)
		
		
		client.videoChannel.delegate = self.videoChannelDelegate
		client.controlChannel.delegate = self.controlChannelDelegate
		client.audioChannel.delegate = self.audioChannelDelegate
		client.delegate = self
		ws.delegate = self
		



	}
	
	private var lastReportTime : Double = -1
	private var lastBytesReceived: Int = -1
	
	@objc func updateStatics() {
		client.getStatus { (report: RTCStatisticsReport) in
			let timeNow = report.timestamp_us
			var bytesNow: Int = 0
			
			
			if let d1 = report.statistics["D1"]?.values["bytesReceived"] as? Int,
			   let d2 = report.statistics["D2"]?.values["bytesReceived"] as? Int,
			   let d3 = report.statistics["D3"]?.values["bytesReceived"] as? Int
			{
				bytesNow = d1 + d2 + d3
			}
			
			if self.lastReportTime != -1 {
				self.buffer.exStatus.`self`.metrics.0.bitrate = Float (bytesNow - self.lastBytesReceived) / Float((timeNow - self.lastReportTime)) * 8
			}
			
			self.lastReportTime = timeNow
			self.lastBytesReceived = bytesNow

			

		}
	}
	
	static func parseSDP (_ s: String) -> [String:Any]{
		let f = s.components(separatedBy: "\r\n")
		var g = [String: Any]()
		for line in f {
			let c = line.split(separator: "=", maxSplits: 1).map(String.init)
			if c.count < 2 {
				continue
			}
			let e = c[0]
			let value = c[1]
			if !e.isEmpty {
				if e == "a" {
					if g["a"] == nil {
						g["a"] = [String: String]()
					}
					if var aDict = g["a"] as? [String: String] {
						let parts = value.split(maxSplits: 1, whereSeparator: { $0 == ":" }).map(String.init)
						if parts.count > 1 {
							aDict[parts[0]] = parts[1]
							g["a"] = aDict
						}

					}
				} else {
					g[e] = value
				}
			}
		}
		return g
	}
	
	func webSocketDidConnect(_ webSocket: WebSocket) {
		print("Connected!")
	}
	
	func webSocket(_ webSocket: WebSocket, didFailWith error: any Error) {
		print("Failed!")
	}
	
	func webSocket(_ webSocket: WebSocket, didReceiveAction type: String, params: [String : Any]) {
		print("receive action! \(type)")
		if type == "closed" {
			buffer.parsecStatus = ParsecStatus(4)
			self.ws.close()
		} else if type == "candex_relay" {
			let data = params["data"] as! [String : Any]
			let ip = data["ip"] as! String
			let port = data["port"] as! Int
			let from_stun = data["from_stun"] as! Bool
			let sdp = "candidate:2395300328 1 udp 2113937151 \(ip) \(port) typ \(from_stun ? "srflx" : "host") generation 0 ufrag \(self.remoteUfrag) network-cost 50";
			let c = RTCIceCandidate(sdp: sdp, sdpMLineIndex: 0, sdpMid: "0")
			self.client.set(remoteCandidate: c, completion: { (err) in
				if let err = err {
					print(err)
				}
			})
		} else if type == "answer_relay" {
			if (!(params["approved"] as! Bool)) {
				self.buffer.parsecStatus = ParsecStatus(4)
				return
			}
			let data = params["data"] as! [String : Any]
			let creds = data["creds"] as! [String : Any]
			let fingerprint = creds["fingerprint"] as! String
			let ice_pwd = creds["ice_pwd"] as! String
			let ice_ufrag = creds["ice_ufrag"] as! String
			let g = "v=0\r\no=- 6033582178177519 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\na=msid-semantic: WMS *\r\nm=application 9 DTLS/SCTP 5000\r\nc=IN IP4 0.0.0.0\r\nb=AS:30\r\na=ice-ufrag:\(ice_ufrag)\r\na=ice-pwd:\(ice_pwd)\r\na=ice-options:trickle\r\na=fingerprint:\(fingerprint)\r\na=setup:active\r\na=mid:0\r\na=sendrecv\r\na=sctpmap:5000 webrtc-datachannel 256\r\na=max-message-size:1073741823\r\n"
			client.set(remoteSdp: RTCSessionDescription(type: .answer, sdp: g), completion: {(err) in
				if let err = err {
					print(err)
				}
			})
			self.remoteUfrag = ice_ufrag
		}
	}
	
	func webSocket(_ webSocket: WebSocket, didCloseWith reason: String?) {
		print("close!")
	}
	
	func webRTCClient(_ client: WebRTCClient, didDiscoverLocalCandidate candidate: RTCIceCandidate) {

		// 要使用UDP
		let sdp = candidate.sdp.replacingOccurrences(of: "candidate:", with: "")
		let f = sdp.components(separatedBy: " ")
		if f.count < 8 || f[2].lowercased() != "udp" {
			return
		}
		let ip = f[4]
		let port = Int(f[5])!
		let isSrlfx = f[7] == "srflx"
		let isHost = f[7] == "host"

		let payloadData = ParsecWsCandexPayloadData(from_stun: isSrlfx, ip: ip, lan: isHost, port: port, sync: false)
		let payload = ParsecWsCandexPayload(attempt_id: self.attemptId, data: payloadData, to: self.peerId)
		
		self.ws.sendAction("candex", payload: payload)
	}
	
	func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState) {
		print("didChangeConnectionState!")
	}
	
	func webRTCClient(_ client: WebRTCClient, didReceiveData data: Data) {
		print("didReceiveData!")
	}

	// MARK: connect
	func connect(_ peerID: String) -> ParsecStatus {
		self.peerId = peerID
		var urlStr :String = ""
		if let session_id = NetworkHandler.clinfo?.session_id{
			urlStr = "wss://kessel-ws.parsec.app:443/?session_id=\(session_id)&role=client&version=1&build=150-91&sdk_version=393216"
		} else {
			return ParsecStatus(4)
		}
		
		ws.connect(toServer: URL(string: urlStr)!)
		
		
		attemptId = UUID.init().uuidString

		client.offer(completion: { (sdp) in
			let parsed = ParsecWeb.parseSDP(sdp.sdp)["a"] as! [String:String]
			let creds = ParsecWsCred(fingerprint: parsed["fingerprint"]!, ice_pwd: parsed["ice-pwd"]!, ice_ufrag: parsed["ice-ufrag"]!)
			let payloadData = ParsecWsOfferPayloadData(creds: creds)
			let payload = ParsecWsOfferPayload(attempt_id: self.attemptId, data: payloadData, to: peerID)

			self.ws.sendAction("offer", payload: payload)
	
		})
		self.statusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStatics), userInfo: nil, repeats: true)
		
		return ParsecStatus(4)
	}

	func disconnect() {
		// Implementation here
		print("Disconnect!")
		ws.close()
		client.close()
		self.statusTimer?.invalidate()
		self.player.stop()
	}

	func getStatus() -> ParsecStatus {
		return buffer.parsecStatus
	}

	func getStatusEx(_ pcs: inout ParsecClientStatus) -> ParsecStatus {
		pcs = self.buffer.exStatus
		return buffer.parsecStatus
	}

	func setFrame(_ width: CGFloat, _ height: CGFloat, _ scale: CGFloat) {
		// Implementation here
	}
	
	private var isFirst = true
	private var _vertexBuffer : GLuint = 1
	private var _indiceBuffer : GLuint = 1
	private let vertices : [GLfloat] = [
		1, -1, 0,  1,1,
		1,1,0,     1,0,
		-1,1,0,    0,0,
		-1,-1,0,   0,1,
	]
	
	private let indicies: [GLubyte] = [
		0,1,2,
		2,3,0
	]
	
	private var program: GLuint = 1
	private var lastTextureName: GLuint = 0
	private var lastTextureName2: GLuint = 0


	func renderGLFrame(timeout: UInt32) {
		var newFrame : CMSampleBuffer?
		
		
		// 直接取出队列的最后一帧,其他全部丢弃
		while true {
			let s = self.buffer.decodedVideoBuffer.dequeue()
			if s == nil {
				break
			}
			newFrame = s
		}
		let data = newFrame ?? self.lastFrame ?? nil
		if let data = data {
			self.lastFrame = data
			
			if (isFirst) {
				program = OpenGLHelpers.compileAndLinkShaderProgram()
				//vertex buffer
				glGenBuffers(1, &_vertexBuffer)
				glBindBuffer(GLbitfield(GL_ARRAY_BUFFER), _vertexBuffer)
				glBufferData(GLbitfield(GL_ARRAY_BUFFER), MemoryLayout<GLfloat>.size * 20, vertices, GLenum(GL_DYNAMIC_DRAW))

				// index buffer
				glGenBuffers(1, &_indiceBuffer)
				glBindBuffer(GLbitfield(GL_ELEMENT_ARRAY_BUFFER), _indiceBuffer)
				glBufferData(GLbitfield(GL_ELEMENT_ARRAY_BUFFER), MemoryLayout<GLubyte>.size * 6, indicies, GLenum(GL_DYNAMIC_DRAW))
				
				isFirst = false
			}
			
			if lastTextureName != 0 {
				glDeleteTextures(1, [lastTextureName])
			}

			let cgImg = data.image?.cgImage
			glGetError()
			let desc = try! GLKTextureLoader.texture(with: cgImg!)
			let textureName : UInt32 = desc.name

			glClearColor(0x66/255.0, 0xcc/255.0, 1.0, 1.0)
			glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
			
			glUseProgram(program)
			glActiveTexture(GLenum(GL_TEXTURE0))
			glBindTexture(GLenum(GL_TEXTURE_2D), textureName)
			
			glEnableVertexAttribArray(0)
			glVertexAttribPointer(0, 3, GLenum(GL_FLOAT), GLboolean(GL_FALSE), Int32(MemoryLayout<GLfloat>.size) * 5,  nil)
			
			glEnableVertexAttribArray(1)
			glVertexAttribPointer(1, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), Int32(MemoryLayout<GLfloat>.size) * 5,  UnsafeRawPointer(bitPattern: 3 * MemoryLayout<GLfloat>.size))
			
			glBindBuffer(GLenum(GL_ARRAY_BUFFER), _vertexBuffer)
			glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), _indiceBuffer)
			
			glDrawElements(GLenum(GL_TRIANGLES), 6, GLenum(GL_UNSIGNED_BYTE), nil)
			
			glDisableVertexAttribArray(0)
			glDisableVertexAttribArray(1)
			glBindTexture(GLenum(GL_TEXTURE_2D), 0)
			glDisable(GLenum(GL_TEXTURE1))

			lastTextureName = textureName
			
			glFlush()
		}

	}

	func setMuted(_ muted: Bool) {
		// Implementation here
	}

	func applyConfig() {
		// Implementation here
	}

	func sendMouseMessage(_ button: ParsecMouseButton, _ x: Int32, _ y: Int32, _ pressed: Bool) {
		// Implementation here
	}

	func sendMouseClickMessage(_ button: ParsecMouseButton, _ pressed: Bool) {
		// Implementation here
	}

	func sendMouseDelta(_ dx: Int32, _ dy: Int32) {
		// Implementation here
	}

	func sendMousePosition(_ x: Int32, _ y: Int32) {
		// Implementation here
	}

	func sendMouseRelativeMove(_ dx: Int32, _ dy: Int32) {
		// Implementation here
	}

	func sendKeyboardMessage(event: KeyBoardKeyEvent) {
		// Implementation here
	}

	func sendGameControllerButtonMessage(controllerId: UInt32, _ button: ParsecGamepadButton, pressed: Bool) {
		// Implementation here
	}

	func sendGameControllerAxisMessage(controllerId: UInt32, _ button: ParsecGamepadAxis, _ value: Int16) {
		// Implementation here
	}

	func sendGameControllerUnplugMessage(controllerId: UInt32) {
		// Implementation here
	}

	func sendWheelMsg(x: Int32, y: Int32) {
		// Implementation here
	}
}
