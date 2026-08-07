import Foundation

/// Talks to Backblaze B2's native HTTP API directly — the one thing neither `rclone` nor the
/// `b2` CLI expose: baking a `Content-Disposition` override into a download-authorization token
/// at the moment it's minted. (Appending that override to an already-issued link just invalidates
/// its signature — confirmed against the real API: 401 bad_auth_token.) Everything else in this
/// app goes through rclone; this is only for the "forzar descarga" share link.
enum B2API {
    private struct AuthResponse: Codable {
        let apiUrl: String
        let downloadUrl: String
        let authorizationToken: String
        let accountId: String
        let allowed: Allowed
        struct Allowed: Codable { let bucketId: String? }
    }

    private struct BucketListResponse: Codable {
        struct Bucket: Codable { let bucketId: String; let bucketName: String }
        let buckets: [Bucket]
    }

    private struct DownloadAuthResponse: Codable {
        let authorizationToken: String
    }

    private static let pathAllowedCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~/")
        return set
    }()

    static func generateForcedDownloadLink(
        accountID: String,
        appKey: String,
        bucketName: String,
        relativePath: String,
        fileName: String,
        expireDays: Int,
        completion: @escaping (String?) -> Void
    ) {
        authorize(accountID: accountID, appKey: appKey) { auth in
            guard let auth else { completion(nil); return }
            resolveBucketID(auth: auth, bucketName: bucketName) { bucketID in
                guard let bucketID else { completion(nil); return }
                getDownloadAuth(auth: auth, bucketID: bucketID, relativePath: relativePath, fileName: fileName, expireDays: expireDays) { token in
                    guard let token else { completion(nil); return }
                    let disposition = "attachment; filename=\"\(fileName)\""
                    let encodedPath = relativePath.addingPercentEncoding(withAllowedCharacters: pathAllowedCharacters) ?? relativePath
                    let encodedDisposition = disposition.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? disposition
                    completion("\(auth.downloadUrl)/file/\(bucketName)/\(encodedPath)?Authorization=\(token)&b2ContentDisposition=\(encodedDisposition)")
                }
            }
        }
    }

    private static func authorize(accountID: String, appKey: String, completion: @escaping (AuthResponse?) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.backblazeb2.com/b2api/v2/b2_authorize_account")!)
        let credentials = Data("\(accountID):\(appKey)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data, let decoded = try? JSONDecoder().decode(AuthResponse.self, from: data) else {
                completion(nil); return
            }
            completion(decoded)
        }.resume()
    }

    /// Restricted application keys (the common case for a saved connection) already carry their
    /// one allowed bucket's ID in the auth response; only a full/master key needs this extra call.
    private static func resolveBucketID(auth: AuthResponse, bucketName: String, completion: @escaping (String?) -> Void) {
        if let bucketID = auth.allowed.bucketId {
            completion(bucketID)
            return
        }
        var request = URLRequest(url: URL(string: "\(auth.apiUrl)/b2api/v2/b2_list_buckets")!)
        request.httpMethod = "POST"
        request.setValue(auth.authorizationToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["accountId": auth.accountId, "bucketName": bucketName])
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data, let decoded = try? JSONDecoder().decode(BucketListResponse.self, from: data),
                  let bucket = decoded.buckets.first(where: { $0.bucketName == bucketName }) else {
                completion(nil); return
            }
            completion(bucket.bucketId)
        }.resume()
    }

    private static func getDownloadAuth(auth: AuthResponse, bucketID: String, relativePath: String, fileName: String, expireDays: Int, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: URL(string: "\(auth.apiUrl)/b2api/v2/b2_get_download_authorization")!)
        request.httpMethod = "POST"
        request.setValue(auth.authorizationToken, forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "bucketId": bucketID,
            "fileNamePrefix": relativePath,
            // B2 hard-caps download-authorization tokens at one week regardless of what's requested.
            "validDurationInSeconds": min(max(expireDays, 1) * 86400, 604800),
            "b2ContentDisposition": "attachment; filename=\"\(fileName)\""
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data, let decoded = try? JSONDecoder().decode(DownloadAuthResponse.self, from: data) else {
                completion(nil); return
            }
            completion(decoded.authorizationToken)
        }.resume()
    }
}
