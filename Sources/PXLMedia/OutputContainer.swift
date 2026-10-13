import Foundation

public enum OutputContainer: String, Codable, Sendable { case mov, mp4 }

public enum MediaOperation: String, Codable, Sendable { case transcode, remux }
