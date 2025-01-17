//
//  DeveloperDiskManager.swift
//  AltServer
//
//  Created by Riley Testut on 2/19/21.
//  Copyright © 2021 Riley Testut. All rights reserved.
//

import Foundation

import AltSign

enum DeveloperDiskError: LocalizedError
{
    case unknownDownloadURL
    case unsupportedOperatingSystem
    case downloadedDiskNotFound
    
    var errorDescription: String? {
        switch self
        {
        case .unknownDownloadURL: return NSLocalizedString("The URL to download the Developer disk image could not be determined.", comment: "")
        case .unsupportedOperatingSystem: return NSLocalizedString("The device's operating system does not support installing Developer disk images.", comment: "")
        case .downloadedDiskNotFound: return NSLocalizedString("DeveloperDiskImage.dmg and its signature could not be found in the downloaded archive.", comment: "")
        }
    }
}

private extension URL
{
    #if STAGING
    static let developerDiskDownloadURLs = URL(string: "https://f000.backblazeb2.com/file/altstore-staging/altserver/developerdisks.json")!
    #else
    static let developerDiskDownloadURLs = URL(string: "https://cdn.altstore.io/file/altstore/altserver/developerdisks.json")!
    #endif
}

private extension DeveloperDiskManager
{
    struct FetchURLsResponse: Decodable
    {
        struct Disks: Decodable
        {
            var iOS: [String: DeveloperDiskURL]?
            var tvOS: [String: DeveloperDiskURL]?
        }
        
        var version: Int
        var disks: Disks
    }
    
    enum DeveloperDiskURL: Decodable
    {
        case archive(URL)
        case separate(diskURL: URL, signatureURL: URL)
        
        private enum CodingKeys: CodingKey
        {
            case archive
            case disk
            case signature
        }
        
        init(from decoder: Decoder) throws
        {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            
            if container.contains(.archive)
            {
                let archiveURL = try container.decode(URL.self, forKey: .archive)
                self = .archive(archiveURL)
            }
            else
            {
                let diskURL = try container.decode(URL.self, forKey: .disk)
                let signatureURL = try container.decode(URL.self, forKey: .signature)
                self = .separate(diskURL: diskURL, signatureURL: signatureURL)
            }
        }
    }
}

class DeveloperDiskManager
{
    func downloadDeveloperDisk(for device: ALTDevice, completionHandler: @escaping (Result<(URL, URL), Error>) -> Void)
    {
        let osVersion = "\(device.osVersion.majorVersion).\(device.osVersion.minorVersion)"
        let osKeyPath: KeyPath<FetchURLsResponse.Disks, [String: DeveloperDiskURL]?>
        
        switch device.type
        {
        case .iphone, .ipad: osKeyPath = \FetchURLsResponse.Disks.iOS
        case .appletv: osKeyPath = \FetchURLsResponse.Disks.tvOS
        default: return completionHandler(.failure(DeveloperDiskError.unsupportedOperatingSystem))
        }
        
        do
        {
            let developerDiskDirectoryURL = FileManager.default.developerDisksDirectory.appendingPathComponent(osVersion)
            try FileManager.default.createDirectory(at: developerDiskDirectoryURL, withIntermediateDirectories: true, attributes: nil)
            
            let developerDiskURL = developerDiskDirectoryURL.appendingPathComponent("DeveloperDiskImage.dmg")
            let developerDiskSignatureURL = developerDiskDirectoryURL.appendingPathComponent("DeveloperDiskImage.dmg.signature")
            
            guard !FileManager.default.fileExists(atPath: developerDiskURL.path) || !FileManager.default.fileExists(atPath: developerDiskSignatureURL.path) else {
                return completionHandler(.success((developerDiskURL, developerDiskSignatureURL)))
            }
            
            func finish(_ result: Result<(URL, URL), Error>)
            {
                do
                {
                    let (diskFileURL, signatureFileURL) = try result.get()
                    
                    let developerDiskDirectoryURL = FileManager.default.developerDisksDirectory.appendingPathComponent(osVersion)
                    try FileManager.default.createDirectory(at: developerDiskDirectoryURL, withIntermediateDirectories: true, attributes: nil)
                    
                    try FileManager.default.copyItem(at: diskFileURL, to: developerDiskURL)
                    try FileManager.default.copyItem(at: signatureFileURL, to: developerDiskSignatureURL)
                    
                    completionHandler(.success((developerDiskURL, developerDiskSignatureURL)))
                }
                catch
                {
                    completionHandler(.failure(error))
                }
            }
            
            self.fetchDeveloperDiskURLs { (result) in
                do
                {
                    let developerDiskURLs = try result.get()
                    guard let diskURL = developerDiskURLs[keyPath: osKeyPath]?[osVersion] else { throw DeveloperDiskError.unknownDownloadURL }
                    
                    switch diskURL
                    {
                    case .archive(let archiveURL): self.downloadDiskArchive(from: archiveURL, completionHandler: finish(_:))
                    case .separate(let diskURL, let signatureURL): self.downloadDisk(from: diskURL, signatureURL: signatureURL, completionHandler: finish(_:))
                    }
                }
                catch
                {
                    finish(.failure(error))
                }
            }
        }
        catch
        {
            completionHandler(.failure(error))
        }
    }
}

private extension DeveloperDiskManager
{
    func fetchDeveloperDiskURLs(completionHandler: @escaping (Result<FetchURLsResponse.Disks, Error>) -> Void)
    {
        let dataTask = URLSession.shared.dataTask(with: .developerDiskDownloadURLs) { (data, response, error) in
            do
            {
                guard let data = data else { throw error! }
                
                let response = try JSONDecoder().decode(FetchURLsResponse.self, from: data)
                completionHandler(.success(response.disks))
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
        
        dataTask.resume()
    }
    
    func downloadDiskArchive(from url: URL, completionHandler: @escaping (Result<(URL, URL), Error>) -> Void)
    {
        let downloadTask = URLSession.shared.downloadTask(with: url) { (fileURL, response, error) in
            do
            {
                guard let fileURL = fileURL else { throw error! }
                defer { try? FileManager.default.removeItem(at: fileURL) }
                
                let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil)
                defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
                
                try FileManager.default.unzipArchive(at: fileURL, toDirectory: temporaryDirectory)
                
                guard let enumerator = FileManager.default.enumerator(at: temporaryDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: temporaryDirectory])
                }
                
                var tempDiskFileURL: URL?
                var tempSignatureFileURL: URL?
                
                for case let fileURL as URL in enumerator
                {
                    switch fileURL.pathExtension.lowercased()
                    {
                    case "dmg": tempDiskFileURL = fileURL
                    case "signature": tempSignatureFileURL = fileURL
                    default: break
                    }
                }
                
                guard let diskFileURL = tempDiskFileURL, let signatureFileURL = tempSignatureFileURL else { throw DeveloperDiskError.downloadedDiskNotFound }
                
                completionHandler(.success((diskFileURL, signatureFileURL)))
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
        
        downloadTask.resume()
    }
    
    func downloadDisk(from diskURL: URL, signatureURL: URL, completionHandler: @escaping (Result<(URL, URL), Error>) -> Void)
    {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        do { try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil) }
        catch { return completionHandler(.failure(error)) }
                
        var diskFileURL: URL?
        var signatureFileURL: URL?
        
        var downloadError: Error?
        
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        dispatchGroup.enter()
                
        let diskDownloadTask = URLSession.shared.downloadTask(with: diskURL) { (fileURL, response, error) in
            do
            {
                guard let fileURL = fileURL else { throw error! }
                
                let destinationURL = temporaryDirectory.appendingPathComponent("DeveloperDiskImage.dmg")
                try FileManager.default.copyItem(at: fileURL, to: destinationURL)
                
                diskFileURL = destinationURL
            }
            catch
            {
                downloadError = error
            }
            
            dispatchGroup.leave()
        }
        
        let signatureDownloadTask = URLSession.shared.downloadTask(with: signatureURL) { (fileURL, response, error) in
            do
            {
                guard let fileURL = fileURL else { throw error! }
                
                let destinationURL = temporaryDirectory.appendingPathComponent("DeveloperDiskImage.dmg.signature")
                try FileManager.default.copyItem(at: fileURL, to: destinationURL)
                
                signatureFileURL = destinationURL
            }
            catch
            {
                downloadError = error
            }
            
            dispatchGroup.leave()
        }
        
        diskDownloadTask.resume()
        signatureDownloadTask.resume()
        
        dispatchGroup.notify(queue: .global(qos: .userInitiated)) {
            defer {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
            
            guard let diskFileURL = diskFileURL, let signatureFileURL = signatureFileURL else {
                return completionHandler(.failure(downloadError ?? DeveloperDiskError.downloadedDiskNotFound))
            }
            
            completionHandler(.success((diskFileURL, signatureFileURL)))
        }
    }
}
