//
//  KingfisherManager+LivePhoto.swift
//  Kingfisher
//
//  Created by onevcat on 2024/10/01.
//
//  Copyright (c) 2024 Wei Wang <onevcat@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

@preconcurrency import Photos

public struct LivePhotoLoadingInfoResult: Sendable {
    
    /// Retrieves the live photo disk URLs from this result.
    public let fileURLs: [URL]

    /// Retrieves the cache source of the image, indicating from which cache layer it was retrieved.
    ///
    /// If the image was freshly downloaded from the network and not retrieved from any cache, `.none` will be returned.
    /// Otherwise, ``CacheType/disk`` will be returned for the live photo. ``CacheType/memory`` is not available for
    /// live photos since it may take too much memory. All cached live photos are loaded from disk only.
    public let cacheType: CacheType

    /// The ``LivePhotoSource`` to which this result is related. This indicates where the `livePhoto` referenced by
    /// `self` is located.
    public let source: LivePhotoSource

    /// The original ``LivePhotoSource`` from which the retrieval task begins. It may differ from the ``source`` property.
    /// When an alternative source loading occurs, the ``source`` will represent the replacement loading target, while the
    /// ``originalSource`` will retain the initial ``source`` that initiated the image loading process.
    public let originalSource: LivePhotoSource
    
    /// Retrieves the data associated with this result.
    ///
    /// When this result is obtained from a network download (when `cacheType == .none`), calling this method returns
    /// the downloaded data. If the result is from the cache, it serializes the image using the specified cache
    /// serializer from the loading options and returns the result.
    ///
    /// - Note: Retrieving this data can be a time-consuming operation, so it is advisable to store it if you need to
    /// use it multiple times and avoid frequent calls to this method.
    public let data: @Sendable () -> [Data]
}

extension KingfisherManager {
    public func retrieveLivePhoto(
        with source: LivePhotoSource,
        options: KingfisherOptionsInfo? = nil,
        progressBlock: DownloadProgressBlock? = nil,
        referenceTaskIdentifierChecker: (() -> Bool)? = nil
    ) async throws -> LivePhotoLoadingInfoResult {
        let fullOptions = currentDefaultOptions + (options ?? .empty)
        var checkedOptions = KingfisherParsedOptionsInfo(fullOptions)
        
        if checkedOptions.processor == DefaultImageProcessor.default {
            // The default processor is a default behavior so we replace it silently.
            checkedOptions.processor = LivePhotoImageProcessor.default
        } else if checkedOptions.processor != LivePhotoImageProcessor.default {
            assertionFailure("[Kingfisher] Using of custom processors during loading of live photo resource is not supported.")
            checkedOptions.processor = LivePhotoImageProcessor.default
        }
        
        if let checker = referenceTaskIdentifierChecker {
            checkedOptions.onDataReceived?.forEach {
                $0.onShouldApply = checker
            }
        }
        
        // TODO. We ignore the retry of live photo now to suppress the complexity.
        
        let missingResources = missingResources(source, options: checkedOptions)
        let resourcesResult = try await downloadAndCache(resources: missingResources, options: checkedOptions)
        
        let targetCache = checkedOptions.targetCache ?? cache
        let fileURLs = source.resources.map {
            targetCache.cacheFileURLIfOnDisk(
                forKey: $0.cacheKey,
                processorIdentifier: checkedOptions.processor.identifier
            )
        }
        if fileURLs.contains(nil) {
            // not all file done. throw error
        }
        return LivePhotoLoadingInfoResult(
            fileURLs: fileURLs.compactMap { $0 },
            cacheType: missingResources.isEmpty ? .disk : .none,
            source: source,
            originalSource: source,
            data: {
                resourcesResult.map { $0.originalData }
            })
    }
    
    func missingResources(_ source: LivePhotoSource, options: KingfisherParsedOptionsInfo) -> [any Resource] {
        let missingResources: [any Resource]
        if options.forceRefresh {
            missingResources = source.resources
        } else {
            let targetCache = options.targetCache ?? cache
            missingResources = source.resources.reduce([], { r, resource in
                let cacheKey = resource.cacheKey
                let existingCachedFileURL = targetCache.cacheFileURLIfOnDisk(
                    forKey: cacheKey,
                    processorIdentifier: options.processor.identifier
                )
                if existingCachedFileURL == nil {
                    return r + [resource]
                } else {
                    return r
                }
            })
        }
        return missingResources
    }
    
    func downloadAndCache(
        resources: [any Resource],
        options: KingfisherParsedOptionsInfo
    ) async throws -> [LivePhotoResourceDownloadingResult] {
        if resources.isEmpty {
            return []
        }
        let downloader = options.downloader ?? downloader
        let cache = options.targetCache ?? cache
        return try await withThrowingTaskGroup(of: LivePhotoResourceDownloadingResult.self) { group in
            for resource in resources {
                group.addTask {
                    let downloadedResource = try await downloader.downloadLivePhotoResource(
                        with: resource.downloadURL,
                        options: options
                    )
                    try await cache.storeToDisk(
                        downloadedResource.originalData,
                        forKey: resource.cacheKey,
                        processorIdentifier: options.processor.identifier,
                        expiration: options.diskCacheExpiration
                    )
                    return downloadedResource
                }
            }
            
            var result: [LivePhotoResourceDownloadingResult] = []
            for try await resource in group {
                result.append(resource)
            }
            return result
        }
    }
}
