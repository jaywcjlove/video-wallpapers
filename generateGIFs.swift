#!/usr/bin/swift

import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

let fileManager = FileManager.default
let currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let videosDir = currentDir.appendingPathComponent("videos")
let outputDir = currentDir.appendingPathComponent("gifs")

try? fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

func resizeImage(_ image: CGImage, maxWidth: CGFloat) -> CGImage? {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let aspect = height / width
    let targetWidth = min(width, maxWidth)
    let targetHeight = targetWidth * aspect
    guard let colorSpace = image.colorSpace else { return nil }
    guard let context = CGContext(data: nil,
                                  width: Int(targetWidth),
                                  height: Int(targetHeight),
                                  bitsPerComponent: image.bitsPerComponent,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: image.bitmapInfo.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    return context.makeImage()
}

func generateGIF(from videoURL: URL, frameCount: Int = 12, maxWidth: CGFloat = 500, outputURL: URL) async {
    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    let durationCMTime: CMTime
    do {
        durationCMTime = try await asset.load(.duration)
    } catch {
        print("Failed to load duration for \(videoURL.lastPathComponent): \(error)")
        return
    }

    let durationSeconds = CMTimeGetSeconds(durationCMTime)
    guard durationSeconds > 0 else { return }

    // 连续提取前12个关键帧，使用更小的间隔确保流畅性
    let interval = 0.08 // 秒，减少间隔以获得更流畅的效果
    let times: [CMTime] = (0..<frameCount).map { i in
        CMTime(seconds: Double(i) * interval, preferredTimescale: 600)
    }

    var images: [CGImage] = []
    
    // 并行提取所有帧以提高效率
    await withTaskGroup(of: (Int, CGImage?).self) { group in
        for (index, time) in times.enumerated() {
            group.addTask {
                await withCheckedContinuation { continuation in
                    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, error in
                        if let cgImage = cgImage, let resized = resizeImage(cgImage, maxWidth: maxWidth) {
                            continuation.resume(returning: (index, resized))
                        } else {
                            print("Failed to extract frame at \(CMTimeGetSeconds(time))s: \(error?.localizedDescription ?? "unknown error")")
                            continuation.resume(returning: (index, nil))
                        }
                    }
                }
            }
        }
        
        // 收集结果并按顺序排列
        var results: [(Int, CGImage?)] = []
        for await result in group {
            results.append(result)
        }
        
        // 按索引排序并过滤出成功的图像
        images = results.sorted { $0.0 < $1.0 }
                        .compactMap { $0.1 }
    }

    guard !images.isEmpty else {
        print("No frames extracted from \(videoURL.lastPathComponent)")
        return
    }

    let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.gif.identifier as CFString, images.count, nil)!
    // 减少帧延迟时间以获得更流畅的GIF动画效果
    let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.12]]
    let gifProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]

    for img in images {
        CGImageDestinationAddImage(destination, img, frameProperties as CFDictionary)
    }
    CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

    if CGImageDestinationFinalize(destination) {
        print("GIF created: \(outputURL.path)")
    } else {
        print("Failed to create GIF: \(outputURL.path)")
    }
}

// --------------- 顶层运行 ---------------

// 获取视频列表
let videoFiles: [URL]
do {
    videoFiles = try fileManager.contentsOfDirectory(at: videosDir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "mp4" }
} catch {
    print("Failed to read videos directory: \(error)")
    exit(1)
}

// 信号量等待所有异步任务完成
let semaphore = DispatchSemaphore(value: 0)

Task {
    for video in videoFiles {
        let outputURL = outputDir.appendingPathComponent(video.deletingPathExtension().lastPathComponent + ".gif")
        await generateGIF(from: video, outputURL: outputURL)
    }
    semaphore.signal()
}

// 等待任务完成
semaphore.wait()