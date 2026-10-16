import SwiftUI
import UIKit

struct PhotoPager: UIViewControllerRepresentable {
  let items: [CameraMedia]
  @Binding var index: Int
  let revision: Int
  let camera: CameraModel
  let onTap: () -> Void
  let onLoaded: (String) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIViewController(context: Context) -> UIPageViewController {
    let vc = UIPageViewController(
      transitionStyle: .scroll, navigationOrientation: .horizontal,
      options: [.interPageSpacing: 16])
    vc.dataSource = context.coordinator
    vc.delegate = context.coordinator
    context.coordinator.pager = vc
    if !items.isEmpty {
      vc.setViewControllers([context.coordinator.page(index)], direction: .forward, animated: false)
    }
    return vc
  }
  func updateUIViewController(_ vc: UIPageViewController, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    guard items.indices.contains(index) else { return }
    let visible = (vc.viewControllers?.first as? ZoomPhotoController)?.index
    if visible != index && !coordinator.transitioning {
      vc.setViewControllers(
        [coordinator.page(index)], direction: index > (visible ?? 0) ? .forward : .reverse,
        animated: false)
      coordinator.trim()
      coordinator.updatePaging()
      let value = coordinator.pages[index]?.loadedDescription ?? "正在载入清晰预览…"
      DispatchQueue.main.async {
        if coordinator.parent.index == index { coordinator.parent.onLoaded(value) }
      }
    }
    if coordinator.revision != revision {
      coordinator.revision = revision
      coordinator.pages[index]?.loadPhoto(force: true)
    }
  }
  @MainActor
  final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    var parent: PhotoPager
    weak var pager: UIPageViewController?
    var pages: [Int: ZoomPhotoController] = [:]
    var transitioning = false
    var revision = 0
    init(_ parent: PhotoPager) { self.parent = parent }
    func page(_ index: Int) -> ZoomPhotoController {
      if let p = pages[index] { return p }
      let p = ZoomPhotoController(index: index, item: parent.items[index], camera: parent.camera)
      p.onTap = { [weak self] in self?.parent.onTap() }
      p.onZoom = { [weak self] in self?.updatePaging() }
      p.onLoaded = { [weak self] value in
        guard let self, self.parent.index == index else { return }
        self.parent.onLoaded(value)
      }
      pages[index] = p
      return p
    }
    func trim() {
      for key in Array(pages.keys) where abs(key - parent.index) > 1 {
        pages[key]?.cancelLoad()
        pages[key] = nil
      }
    }
    func updatePaging() {
      let zoomed = (pager?.viewControllers?.first as? ZoomPhotoController)?.isZoomed ?? false
      pager?.view.subviews.compactMap { $0 as? UIScrollView }.forEach {
        $0.isScrollEnabled = !zoomed
      }
    }
    func pageViewController(
      _ pageViewController: UIPageViewController, viewControllerBefore vc: UIViewController
    ) -> UIViewController? {
      guard let current = vc as? ZoomPhotoController, current.index > 0 else { return nil }
      return page(current.index - 1)
    }
    func pageViewController(
      _ pageViewController: UIPageViewController, viewControllerAfter vc: UIViewController
    ) -> UIViewController? {
      guard let current = vc as? ZoomPhotoController, current.index + 1 < parent.items.count else {
        return nil
      }
      return page(current.index + 1)
    }
    func pageViewController(
      _ vc: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]
    ) { transitioning = true }
    func pageViewController(
      _ vc: UIPageViewController, didFinishAnimating finished: Bool,
      previousViewControllers: [UIViewController], transitionCompleted completed: Bool
    ) {
      transitioning = false
      if completed, let p = vc.viewControllers?.first as? ZoomPhotoController {
        parent.index = p.index
        parent.onLoaded(p.loadedDescription)
        trim()
        updatePaging()
      }
    }
  }
}
@MainActor final class ZoomPhotoController: UIViewController, UIScrollViewDelegate {
  let index: Int
  let item: CameraMedia
  let camera: CameraModel
  let scroll = UIScrollView()
  let imageView = UIImageView()
  let spinner = UIActivityIndicatorView(style: .medium)
  let retry = UIButton(type: .system)
  var onTap: (() -> Void)?
  var onZoom: (() -> Void)?
  var onLoaded: ((String) -> Void)?
  private var task: Task<Void, Never>?
  private var imageIdentity = ""
  private var loadID = UUID()
  private var laidOutSize = CGSize.zero
  var loadedDescription = "正在载入清晰预览…"
  var isZoomed: Bool { scroll.zoomScale > scroll.minimumZoomScale * 1.02 }
  init(index: Int, item: CameraMedia, camera: CameraModel) {
    self.index = index
    self.item = item
    self.camera = camera
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("Storyboard is not used") }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    scroll.frame = view.bounds
    scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    scroll.delegate = self
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.bouncesZoom = true
    scroll.accessibilityIdentifier = "zoomPhoto-\(item.id)"
    imageView.contentMode = .scaleAspectFit
    imageView.isAccessibilityElement = true
    imageView.accessibilityIdentifier = "photoImage-\(item.id)"
    scroll.addSubview(imageView)
    view.addSubview(scroll)
    spinner.color = .white
    spinner.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    retry.setTitle("重试清晰预览", for: .normal)
    retry.tintColor = .white
    retry.backgroundColor = UIColor.black.withAlphaComponent(0.75)
    retry.layer.cornerRadius = 18
    var configuration = UIButton.Configuration.plain()
    configuration.title = "重试清晰预览"
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 10, leading: 16, bottom: 10, trailing: 16)
    retry.configuration = configuration
    retry.translatesAutoresizingMaskIntoConstraints = false
    retry.isHidden = true
    retry.addTarget(self, action: #selector(retryPhoto), for: .touchUpInside)
    view.addSubview(retry)
    NSLayoutConstraint.activate([
      retry.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      retry.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoom(_:)))
    doubleTap.numberOfTapsRequired = 2
    let singleTap = UITapGestureRecognizer(target: self, action: #selector(tap))
    singleTap.require(toFail: doubleTap)
    scroll.addGestureRecognizer(doubleTap)
    scroll.addGestureRecognizer(singleTap)
    if let thumbnail = camera.thumbnailImage(item) { setImage(thumbnail) }
    loadPhoto()
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if imageIdentity.isEmpty { loadPhoto() }
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    cancelLoad()
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if laidOutSize != scroll.bounds.size {
      laidOutSize = scroll.bounds.size
      fitImage()
    }
    centerImage()
  }
  func cancelLoad() {
    task?.cancel()
    task = nil
  }
  func loadPhoto(force: Bool = false) {
    guard isViewLoaded, task == nil || force else { return }
    task?.cancel()
    let token = UUID()
    loadID = token
    spinner.startAnimating()
    retry.isHidden = true
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let original = camera.localOriginal(item) != nil
        let result = try await camera.photo(item, original: original)
        try Task.checkCancellation()
        guard token == loadID else { return }
        setImage(result.image)
        imageIdentity = item.cacheKey + result.quality
        loadedDescription = "\(result.quality) · \(result.dimensions)"
        imageView.accessibilityLabel = "\(item.title)，\(loadedDescription)"
        onLoaded?(loadedDescription)
        spinner.stopAnimating()
        task = nil
      } catch is CancellationError {
        guard token == loadID else { return }
        spinner.stopAnimating()
        task = nil
      } catch {
        guard token == loadID else { return }
        spinner.stopAnimating()
        retry.isHidden = false
        task = nil
        loadedDescription = error.localizedDescription
        onLoaded?(loadedDescription)
      }
    }
  }
  private func setImage(_ image: UIImage) {
    let relativeZoom = scroll.minimumZoomScale > 0 ? scroll.zoomScale / scroll.minimumZoomScale : 1
    let oldCenter = imageView.convert(
      CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), from: scroll)
    let normalized = CGPoint(
      x: imageView.bounds.width > 0 ? oldCenter.x / imageView.bounds.width : 0.5,
      y: imageView.bounds.height > 0 ? oldCenter.y / imageView.bounds.height : 0.5)
    // Thumbnail fit can be greater than 1. Lower the old bounds BEFORE
    // resetting zoom, otherwise UIKit clamps 1 and carries that transform
    // into the new image's frame, shrinking the high-resolution replacement.
    scroll.minimumZoomScale = 0.001
    scroll.maximumZoomScale = 64
    scroll.setZoomScale(1, animated: false)
    scroll.contentInset = .zero
    imageView.image = image
    imageView.frame = CGRect(origin: .zero, size: image.size)
    scroll.contentSize = image.size
    fitImage()
    if relativeZoom > 1.05 {
      let scale = min(scroll.maximumZoomScale, scroll.minimumZoomScale * relativeZoom)
      let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
      scroll.zoom(
        to: CGRect(
          x: normalized.x * image.size.width - size.width / 2,
          y: normalized.y * image.size.height - size.height / 2,
          width: size.width, height: size.height), animated: false)
    }
  }
  private func fitImage() {
    guard let image = imageView.image, scroll.bounds.width > 0, image.size.width > 0 else { return }
    let scale = min(
      scroll.bounds.width / image.size.width, scroll.bounds.height / image.size.height)
    scroll.minimumZoomScale = scale
    scroll.maximumZoomScale = max(scale * 6, 1)
    scroll.zoomScale = scale
    centerImage()
    updateZoomAccessibility()
  }
  private func centerImage() {
    let size = imageView.frame.size
    scroll.contentInset = UIEdgeInsets(
      top: max(0, (scroll.bounds.height - size.height) / 2),
      left: max(0, (scroll.bounds.width - size.width) / 2), bottom: 0, right: 0)
  }
  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    centerImage()
    updateZoomAccessibility()
    onZoom?()
  }
  private func updateZoomAccessibility() {
    scroll.accessibilityValue = String(
      format: "%.1f×", scroll.zoomScale / max(scroll.minimumZoomScale, 0.001))
  }
  @objc private func zoom(_ gesture: UITapGestureRecognizer) {
    if isZoomed {
      scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
    } else {
      let scale = min(scroll.maximumZoomScale, scroll.minimumZoomScale * 3)
      let point = gesture.location(in: imageView)
      let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
      scroll.zoom(
        to: CGRect(
          x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width,
          height: size.height), animated: true)
    }
  }
  @objc private func tap() { onTap?() }
  @objc private func retryPhoto() { loadPhoto(force: true) }
}
