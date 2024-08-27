//
//  ScreenCaptureKit-Recording-example
//
//  Created by Tom Lokhorst on 2023-01-18.
//

import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import VideoToolbox
import Foundation

enum RecordMode {
    case h264_sRGB
    case hevc_displayP3

    // I haven't gotten HDR recording working yet.
    // The commented out code is my best attempt, but still results in "blown out whites".
    //
    // Any tips are welcome!
    // - Tom
//    case hevc_displayP3_HDR
}

// Create a screen recording
do {
    // Check for screen recording permission, make sure your terminal has screen recording permission
    guard CGPreflightScreenCaptureAccess() else {
        throw RecordingError("No screen capture permission")
    }

  let streamConfig = SCStreamConfiguration()
                let displayID = CGMainDisplayID()

        // Configure audio capture.
        streamConfig.capturesAudio = true
        streamConfig.excludesCurrentProcessAudio = true
        streamConfig.showsCursor = false // Hide mouse
        let displaySize = CGDisplayBounds(displayID).size

        // The number of physical pixels that represent a logic point on screen, currently 2 for MacBook Pro retina displays
        let displayScaleFactor: Int = 2
        // Configure the window content width and height.
        streamConfig.width = Int(displaySize.width) * displayScaleFactor
        streamConfig.height =  Int(displaySize.height) * displayScaleFactor
        print()
        // Increase the depth of the frame queue to ensure high fps at the expense of increasing
        // the memory footprint of WindowServer.
        streamConfig.queueDepth = 5
                let sharableContent = try await SCShareableContent.current

           guard let display = sharableContent.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError("Can't find display with ID \(displayID) in sharable content")
        }
        let screenCaptureEngine = ScreenCaptureEngine()
        let avWriter : AVWriter = AVWriter()
        let filter = SCContentFilter(display: display, excludingWindows: [])
        screenCaptureEngine.avWriter = avWriter
        print("Starting screen recording of main display")
        screenCaptureEngine.startCapture(configuration: streamConfig, filter: filter)


        print("Hit Return to end recording")
        _ = readLine()
        let result = try? await screenCaptureEngine.stopCapture()
        print(result)

        print("Recording ended, opening video")
} catch {
    print("Error during recording:", error)
}



@available(macOS 13.0, *)
class ScreenCaptureEngine: NSObject, @unchecked Sendable {
    public var  avWriter : AVWriter?
    private var stream: SCStream?
    private let videoSampleBufferQueue = DispatchQueue(label: "com.marzent.XIVOnMac.VideoCapture")
    private let audioSampleBufferQueue = DispatchQueue(label: "com.marzent.XIVOnMac.AudioCapture")
	private var streamOutput: CaptureEngineStreamOutput? = nil
    public let audioEngine = AVAudioEngine()

func startRecording() throws {

    let inputNode = audioEngine.inputNode
    let srate = inputNode.inputFormat(forBus: 0).sampleRate
    print("sample rate = \(srate)")
    if srate == 0 {
        exit(0);
    }

    let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, 
        bufferSize: 1024, 
        format: recordingFormat) { 
            (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            let n = buffer.frameLength
            let c = buffer.stride
            // if flag == 0 { 
            //     print( "num samples  = \(n)") ; 
            //     print( "num channels = \(c)") ; 
            //     flag = 1 
            // }
        }

    try audioEngine.start()
}
    /// - Tag: StartCapture
    func startCapture(configuration: SCStreamConfiguration, filter: SCContentFilter) {
        do {
			let streamOutput = CaptureEngineStreamOutput()
			// Need to keep a reference to this so that it's not discarded when we start recording
			self.streamOutput = streamOutput
            if let avWriter = self.avWriter
            {
                streamOutput.avWriter = avWriter
                avWriter.startRecording(height: Int(configuration.height), width: Int(configuration.width))
                do { try startRecording() } catch { print("Error starting audio recording", error) }
            }
            stream = SCStream(filter: filter, configuration: configuration, delegate: streamOutput)
            
            // Add a stream output to capture screen content.
            try stream?.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: videoSampleBufferQueue)
            try stream?.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: audioSampleBufferQueue)
            stream?.startCapture()
            print("XIV Screen Recording: ")
        } catch {
            print("XIV Screen Recording: Failed to start screen recording \(error)")
        }
    }
    
    @discardableResult
    func stopCapture() async -> URL? {
        var result : URL? = nil
        do {
            try await stream?.stopCapture()
        } catch {
            print("XIV Screen Recording: Error stopping screen recording \(error)")
        }
        if let avWriter = self.avWriter {
            result = await avWriter.stopRecording()
        }
        print("result", result)
        return result
    }
    
    func update(configuration: SCStreamConfiguration, filter: SCContentFilter) async {
        do {
            try await stream?.updateConfiguration(configuration)
            try await stream?.updateContentFilter(filter)
        } catch {
            print("Failed to update the stream session: \(String(describing: error))")
        }
    }
}

@available(macOS 13.0, *)
private class CaptureEngineStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    
    public var avWriter : AVWriter?
    
    private func isValidFrame(for sampleBuffer: CMSampleBuffer) -> Bool {

            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                                 createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentsArray.first
            else {
                return false
            }

            guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete
            else {
                return false
            }

            guard let pixelBuffer = sampleBuffer.imageBuffer else {
                return false
            }

            // We don't need to use any of these, we're just sanity checking that they're there.
            guard let _ = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue(), // SurfaceRef/Backing IOSurface
                  let contentRectDict = attachments[.contentRect],
                  let _ = CGRect(dictionaryRepresentation: contentRectDict as! CFDictionary), // contentRect
                  let _ = attachments[.contentScale] as? CGFloat, // contentScale
                  let _ = attachments[.scaleFactor] as? CGFloat // scaleFactor
            else {
                return false
            }

            return true
        }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        
        // Return early if the sample buffer is invalid.
        guard sampleBuffer.isValid else { return }
        
        // Determine which type of data the sample buffer contains.
        switch outputType {
        case .screen:
            guard isValidFrame(for: sampleBuffer) else {
                            return
                        }
            avWriter?.recordVideo(sampleBuffer: sampleBuffer)
        case .audio:

            avWriter?.recordAudio(sampleBuffer: sampleBuffer)
        @unknown default:
            fatalError("Encountered unknown stream output type: \(outputType)")
        }
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("XIV Screen Recording: An error occurred while capturing: \(error)")
    }
}

@available(macOS 13.0, *)
class AVWriter {

    private(set) var assetWriter: AVAssetWriter?
    private var assetWriterVideoInput: AVAssetWriterInput?
    private var assetWriterAudioInput: AVAssetWriterInput?

    private(set) var isRecording = false
    public var currentRecordingURL : URL? = nil

    init() {}

    private func getRecordingPath() -> URL {
        
        let recordingLocation : URL

        recordingLocation = URL(filePath: FileManager.default.currentDirectoryPath)
   
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        formatter.timeZone = NSTimeZone.local
        let now = Date()
        let formatted = formatter.string(from: now)
        let filename = " Recording \(formatted).mov"
        
        // I *suppose* the most correct thing to do is check for duplicates but hardly seems worth the effort with the timestamp.
        let finalPath : URL = recordingLocation.appending(component: filename)
        print(finalPath)
        print("Screen Recording: Creating new recording at \(finalPath)")
        return finalPath
    }

    func startRecording(height: Int, width: Int) {
        print("Starting recording", height, width)
        let filePath = getRecordingPath()
        currentRecordingURL = filePath
        guard let assetWriter = try? AVAssetWriter(url: filePath, fileType: .mov) else {
            return
        }

        // Add an audio input
        let audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
        ] as [String: Any]

        let assetWriterAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        assetWriterAudioInput.expectsMediaDataInRealTime = true
        assetWriter.add(assetWriterAudioInput)

        var chosenCodec : AVVideoCodecType

        chosenCodec = AVVideoCodecType.hevc
        
        let videoSettings = [
            AVVideoCodecKey: chosenCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ] as [String: Any]

        // Add a video input
        let assetWriterVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        assetWriterVideoInput.expectsMediaDataInRealTime = true
        assetWriter.add(assetWriterVideoInput)

        self.assetWriter = assetWriter
        self.assetWriterAudioInput = assetWriterAudioInput
        self.assetWriterVideoInput = assetWriterVideoInput
        isRecording = true
    }

    func stopRecording() async -> URL? {
        guard let assetWriter = assetWriter else {
            return nil
        }

        self.isRecording = false
        self.assetWriter = nil
		if assetWriter.status == .writing
		{
			await assetWriter.finishWriting()
			return assetWriter.outputURL
		}
		
		return nil
        
    }

    func recordVideo(sampleBuffer: CMSampleBuffer) {
        guard isRecording,
              let assetWriter = assetWriter
        else {
            return
        }

        if assetWriter.status == .unknown {
            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        } else if assetWriter.status == .writing {
            if let input = assetWriterVideoInput {
                input.append(sampleBuffer)
            }
        } else {
            print("Error writing video - \(assetWriter.error?.localizedDescription ?? "Unknown error")")
        }
    }
    
    func recordAudio(sampleBuffer: CMSampleBuffer) {
        guard isRecording,
              let assetWriter = assetWriter,
              assetWriter.status == .writing,
              let input = assetWriterAudioInput,
              input.isReadyForMoreMediaData
        else {
            return
                }
                print("Recording audio")
        input.append(sampleBuffer)
    }
}

struct RecordingError: Error, CustomDebugStringConvertible {
    var debugDescription: String
    init(_ debugDescription: String) { self.debugDescription = debugDescription }
}
