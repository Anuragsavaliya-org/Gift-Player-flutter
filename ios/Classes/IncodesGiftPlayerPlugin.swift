import CoreVideo
import Flutter
import UIKit
import libpag

/// Native half of the gift player on iOS: PAG playback through libpag (Metal).
///
/// Every PAG gift is a `PagInstance`: a `PAGPlayer` that renders into a `CVPixelBuffer`, which Flutter shows as a texture (so the gift
/// is composited by Flutter and is transparent over whatever is behind it). Dart drives the animation frame by frame (`pagRender` with
/// a progress value), exactly like the web package drives libpag, so loops, pause, seek and the events behave the same for every
/// format. This mirrors the Android implementation method for method.
///
/// libpag work runs on one serial queue; results are delivered on the main thread.
public class IncodesGiftPlayerPlugin: NSObject, FlutterPlugin {
  private let registrar: FlutterPluginRegistrar
  private let textures: FlutterTextureRegistry
  private let work = DispatchQueue(label: "com.incodes.gift_player.pag")
  private var instances = [Int: PagInstance]()  // only touched on `work`
  private var nextId = 1

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    self.textures = registrar.textures()
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "incodes_gift_player", binaryMessenger: registrar.messenger())
    let instance = IncodesGiftPlayerPlugin(registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  /// Failure that maps to a Dart `GiftErrorCode` (the code string is the kebab-case id).
  struct PagError: Error {
    let code: String
    let message: String
  }

  // MARK: - dispatch

  /// Runs `block` on the libpag queue and answers on the main thread.
  private func run(_ result: @escaping FlutterResult, _ block: @escaping () throws -> Any?) {
    work.async {
      do {
        let value = try block()
        DispatchQueue.main.async { result(value) }
      } catch let e as PagError {
        DispatchQueue.main.async { result(FlutterError(code: e.code, message: e.message, details: nil)) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "decode-failed", message: "\(error)", details: nil)) }
      }
    }
  }

  private func instance(_ args: [String: Any]) throws -> PagInstance {
    guard let id = (args["id"] as? NSNumber)?.intValue else { throw PagError(code: "invalid-input", message: "Missing instance id.") }
    guard let inst = instances[id] else { throw PagError(code: "invalid-input", message: "The PAG gift \(id) is already released.") }
    return inst
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pagInit":
      // libpag is linked statically through the pod; there is nothing to load, but touching the class proves it is present.
      run(result) {
        _ = PAGFile.MaxSupportedTagLevel()
        return nil
      }
    case "pagCreate":
      create(args, result)
    case "pagRender":
      run(result) {
        let inst = try self.instance(args)
        inst.player.setProgress((args["progress"] as? NSNumber)?.doubleValue ?? 0)
        inst.player.flush()
        let id = inst.textureId
        DispatchQueue.main.async { self.textures.textureFrameAvailable(id) }
        return nil
      }
    case "pagResize":
      run(result) {
        let inst = try self.instance(args)
        let w = (args["width"] as? NSNumber)?.intValue ?? 0
        let h = (args["height"] as? NSNumber)?.intValue ?? 0
        if w > 0 && h > 0 { try inst.resize(width: w, height: h) }
        return nil
      }
    case "pagSetScaleMode":
      run(result) {
        let inst = try self.instance(args)
        inst.player.setScaleMode(PAGScaleMode(rawValue: UInt32((args["mode"] as? NSNumber)?.intValue ?? 2)))
        return nil
      }
    case "pagGetTextData":
      run(result) {
        let inst = try self.instance(args)
        let index = (args["index"] as? NSNumber)?.int32Value ?? 0
        guard let t = inst.file.getTextData(index) else { throw PagError(code: "invalid-input", message: "No editable text \(index).") }
        return Self.textToMap(t)
      }
    case "pagReplaceText":
      run(result) {
        let inst = try self.instance(args)
        let index = (args["index"] as? NSNumber)?.int32Value ?? 0
        guard let t = inst.file.getTextData(index) else { throw PagError(code: "invalid-input", message: "No editable text \(index).") }
        Self.applyTextMap(t, args["doc"] as? [String: Any] ?? [:])
        inst.file.replaceText(index, data: t)
        return nil
      }
    case "pagSetLayerText":
      run(result) {
        let inst = try self.instance(args)
        let name = args["name"] as? String ?? ""
        var changed = 0
        for layer in inst.file.getLayers(byName: name) ?? [] {
          guard layer.layerType() == PAGLayerType(rawValue: 3)!, let t = layer as? PAGTextLayer else { continue }
          t.setText(args["text"] as? String ?? "")
          if let size = (args["size"] as? NSNumber)?.doubleValue { t.setFontSize(CGFloat(size)) }
          if let color = (args["color"] as? NSNumber)?.int64Value { t.setFillColor(Self.color(fromARGB: color)) }
          changed += 1
        }
        return changed
      }
    case "pagReplaceImage":
      run(result) {
        let inst = try self.instance(args)
        let index = (args["index"] as? NSNumber)?.int32Value ?? 0
        guard let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data else { throw PagError(code: "invalid-input", message: "Missing image bytes.") }
        guard let cg = UIImage(data: bytes)?.cgImage else { throw PagError(code: "decode-failed", message: "The replacement image could not be decoded.") }
        guard let image = PAGImage.FromCGImage(cg) else { throw PagError(code: "decode-failed", message: "libpag could not use the replacement image.") }
        image.setScaleMode(PAGScaleMode(rawValue: UInt32((args["scaleMode"] as? NSNumber)?.intValue ?? 1)))
        inst.file.replaceImage(index, data: image)
        inst.images[Int(index)] = image  // keep alive while it is in use; the previous one is released here
        return nil
      }
    case "pagSetLayerVisible":
      run(result) {
        let inst = try self.instance(args)
        var layers: [PAGLayer] = []
        if let name = args["name"] as? String { layers = inst.file.getLayers(byName: name) ?? [] }
        if layers.isEmpty, let index = (args["index"] as? NSNumber)?.int32Value, let type = (args["type"] as? NSNumber)?.intValue,
          let layerType = PAGLayerType(rawValue: type)
        {
          layers = inst.file.getLayers(byEditableIndex: index, layerType: layerType) ?? []
        }
        let visible = (args["visible"] as? Bool) ?? true
        for l in layers { l.setVisible(visible) }
        return layers.count
      }
    case "pagDispose":
      let id = (args["id"] as? NSNumber)?.intValue ?? 0
      run(result) {
        if let inst = self.instances.removeValue(forKey: id) { inst.release(self.textures) }
        return nil
      }
    case "pagRegisterFont":
      run(result) {
        guard let path = args["path"] as? String else { throw PagError(code: "invalid-input", message: "Missing font path.") }
        guard FileManager.default.fileExists(atPath: path) else { throw PagError(code: "invalid-input", message: "The font file does not exist.") }
        guard PAGFont.RegisterFont(path) != nil else { throw PagError(code: "decode-failed", message: "libpag could not register this font.") }
        return nil
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - create

  private func create(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data else {
      result(FlutterError(code: "invalid-input", message: "Missing PAG bytes.", details: nil))
      return
    }
    let reqW = (args["width"] as? NSNumber)?.intValue ?? 0
    let reqH = (args["height"] as? NSNumber)?.intValue ?? 0
    run(result) {
      let file: PAGFile? = bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return nil }
        return PAGFile.Load(base, size: bytes.count)
      }
      guard let file = file else {
        throw PagError(code: "parse-failed", message: "The PAG engine could not parse this file (corrupt, or newer than the engine supports).")
      }
      let w = reqW > 0 ? reqW : Int(file.width())
      let h = reqH > 0 ? reqH : Int(file.height())
      let inst = try PagInstance(file: file, width: w, height: h)
      let id = self.nextId
      self.nextId += 1
      inst.id = id
      inst.textureId = self.textures.register(inst)
      self.instances[id] = inst

      let textType = PAGLayerType(rawValue: 3)!
      let imageType = PAGLayerType(rawValue: 5)!
      let textIdx = (file.getEditableIndices(textType) ?? []).map { $0.int32Value }
      let imageIdx = (file.getEditableIndices(imageType) ?? []).map { $0.int32Value }
      func names(_ indices: [Int32], _ type: PAGLayerType) -> [String] {
        return indices.map { file.getLayers(byEditableIndex: $0, layerType: type)?.first?.layerName() ?? "" }
      }
      return [
        "id": id,
        "textureId": inst.textureId,
        "width": Int(file.width()),
        "height": Int(file.height()),
        "duration": Int(file.duration()),  // microseconds
        "frameRate": Double(file.frameRate()),
        "textIndices": textIdx.map { Int($0) },
        "imageIndices": imageIdx.map { Int($0) },
        "textNames": names(textIdx, textType),
        "imageNames": names(imageIdx, imageType),
      ] as [String: Any]
    }
  }

  // MARK: - text documents

  static func argb(of color: UIColor?) -> Int64 {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    (color ?? .black).getRed(&r, green: &g, blue: &b, alpha: &a)
    let ia = Int64(255), ir = Int64((r * 255).rounded()), ig = Int64((g * 255).rounded()), ib = Int64((b * 255).rounded())
    return (ia << 24) | (ir << 16) | (ig << 8) | ib  // libpag colours are opaque RGB
  }

  static func color(fromARGB v: Int64) -> UIColor {
    return UIColor(
      red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
  }

  static func textToMap(_ t: PAGText) -> [String: Any] {
    return [
      "text": t.text ?? "",
      "fontSize": Double(t.fontSize),
      "fontFamily": t.fontFamily ?? "",
      "fontStyle": t.fontStyle ?? "",
      "fillColor": argb(of: t.fillColor),
      "strokeColor": argb(of: t.strokeColor),
      "strokeWidth": Double(t.strokeWidth),
      "applyFill": t.applyFill,
      "applyStroke": t.applyStroke,
      "justification": Int(t.justification),
      "fauxBold": t.fauxBold,
    ]
  }

  static func applyTextMap(_ t: PAGText, _ m: [String: Any]) {
    if let v = m["text"] as? String { t.text = v }
    if let v = (m["fontSize"] as? NSNumber)?.floatValue { t.fontSize = v }
    if let v = m["fontFamily"] as? String { t.fontFamily = v }
    if let v = m["fontStyle"] as? String { t.fontStyle = v }
    if let v = (m["fillColor"] as? NSNumber)?.int64Value { t.fillColor = color(fromARGB: v) }
    if let v = (m["strokeColor"] as? NSNumber)?.int64Value { t.strokeColor = color(fromARGB: v) }
    if let v = (m["strokeWidth"] as? NSNumber)?.floatValue { t.strokeWidth = v }
    if let v = m["applyFill"] as? Bool { t.applyFill = v }
    if let v = m["applyStroke"] as? Bool { t.applyStroke = v }
    if let v = (m["justification"] as? NSNumber)?.uint8Value { t.justification = v }
    if let v = m["fauxBold"] as? Bool { t.fauxBold = v }
  }
}

/// One PAG gift: the file, a player, and the pixel buffer Flutter samples as a texture.
final class PagInstance: NSObject, FlutterTexture {
  var id = 0
  var textureId: Int64 = 0
  let file: PAGFile
  let player = PAGPlayer()
  var images = [Int: PAGImage]()
  private var surface: PAGSurface
  private var pixelBuffer: CVPixelBuffer
  private let lock = NSLock()

  init(file: PAGFile, width: Int, height: Int) throws {
    self.file = file
    let pb = try PagInstance.makeBuffer(width: width, height: height)
    guard let s = PAGSurface.FromCVPixelBuffer(pb) else {
      throw IncodesGiftPlayerPlugin.PagError(code: "unsupported-format", message: "Could not create a PAG surface (Metal unavailable or out of memory).")
    }
    self.pixelBuffer = pb
    self.surface = s
    super.init()
    player.setSurface(s)
    player.setComposition(file)
    player.setScaleMode(PAGScaleMode(rawValue: 2))  // letterbox (aspectFit); Dart sets the real mode right after
  }

  /// A BGRA, IOSurface-backed, Metal-compatible buffer (the format libpag renders into and Flutter can sample).
  static func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    let attrs: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var out: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
    guard status == kCVReturnSuccess, let pb = out else {
      throw IncodesGiftPlayerPlugin.PagError(code: "unsupported-format", message: "Could not allocate a \(width)x\(height) pixel buffer (out of memory).")
    }
    return pb
  }

  /// New buffer at the new size; the player is pointed at a new surface over it.
  func resize(width: Int, height: Int) throws {
    let pb = try PagInstance.makeBuffer(width: width, height: height)
    guard let s = PAGSurface.FromCVPixelBuffer(pb) else {
      throw IncodesGiftPlayerPlugin.PagError(code: "unsupported-format", message: "Could not resize the PAG surface.")
    }
    lock.lock()
    pixelBuffer = pb
    surface = s
    lock.unlock()
    player.setSurface(s)
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    return Unmanaged.passRetained(pixelBuffer)
  }

  func release(_ registry: FlutterTextureRegistry) {
    registry.unregisterTexture(textureId)
    player.setSurface(nil)
    images.removeAll()
  }
}
