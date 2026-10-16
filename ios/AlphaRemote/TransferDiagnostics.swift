#if DEBUG
  import Foundation

  struct TransferSpeedSample: Codable {
    let chunkMiB: Int
    let bytes: Int64
    let seconds: Double
    let mibPerSecond: Double
    let sha256: String
  }
  extension CameraModel {
    // A bounded developer measurement. Re-reads one small file with the same
    // disk/identity/checkpoint path as export; creates no camera files.
    func measureTransferSpeed() async {
      guard connected else { return }
      selectedTab = 1
      await stopLive()
      if media.isEmpty { await loadMedia() }
      guard
        let item = media.first(where: {
          $0.files.contains { !$0.video && $0.size >= 16 << 20 && $0.size <= 64 << 20 }
        }),
        let file = item.files.first(where: {
          !$0.video && $0.size >= 16 << 20 && $0.size <= 64 << 20
        })
      else {
        error = "测速需要一份 16～64 MiB 的相机文件"
        return
      }
      busy = true
      importing = true
      bridge.cancelPendingPreviews()
      defer {
        busy = false
        importing = false
      }
      var samples: [TransferSpeedSample] = []
      let destination = bridge.directory.deletingLastPathComponent().appendingPathComponent(
        "transfer-benchmarks.json")
      do {
        for chunk in [2, 8, 16, 16, 8, 2] {
          message = "正在测试 \(chunk) MiB 分段，\(samples.count+1)/6"
          let sample: TransferSpeedSample = try await bridge.call(
            "benchmarkTransfer", ["id": item.id, "fileID": file.id, "chunkMiB": chunk],
            priority: .transfer)
          samples.append(sample)
          try JSONEncoder().encode(samples).write(to: destination, options: .atomic)
        }
        guard Set(samples.map(\.sha256)).count == 1 else {
          throw CameraFailure(message: "测速文件校验和不同，未选择新的分段大小")
        }
        let best =
          [2, 8, 16].max { a, b in
            let left = samples.filter { $0.chunkMiB == a }.map(\.mibPerSecond).reduce(0, +)
            let right = samples.filter { $0.chunkMiB == b }.map(\.mibPerSecond).reduce(0, +)
            return left < right
          } ?? 8
        transferChunkMiB = best
        message = "测速完成：\(best) MiB 分段在本轮平均速度最高"
        importedFile = destination
      } catch { self.error = error.localizedDescription }
    }
  }
#endif
