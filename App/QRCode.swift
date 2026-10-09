// An address's link as a QR code (draft/sharing.md), a group's join code as one (draft/groups.md),
// and on iPhone and iPad, the camera that reads one back. A Mac has no camera pointed at a node, so it takes a link or an address pasted in.

import CoreImage
import SwiftUI
import TernKit
#if os(iOS)
import AVFoundation
import UIKit
#endif

/// The address's link as a QR code: black on white whatever the appearance, since some scanners
/// will not read a code the other way round, at level L, the lowest, which keeps the code small.
struct QRCodeView: View {
    let address: Address

    var body: some View {
        if let image = Self.image(Sharing.link(address)) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280)
                .accessibilityLabel("QR code of the link to this address")
        }
    }

    private static func image(_ text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // One pixel a module here, so the light margin ISO/IEC 18004 asks for, four modules, is
        // four pixels of white round the code, whatever size it is then drawn at.
        let white = CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -4, dy: -4))
        let framed = output.composited(over: white)
        return CIContext().createCGImage(framed, from: framed.extent)
    }
}

/// A join code's link as a QR code, from TernKit's encoder: alphanumeric either side of the `#`,
/// which keeps any code to version 4, where Core Image's generator writes it all as bytes. Black on
/// white whatever the appearance, with the four modules of light margin ISO/IEC 18004 asks for.
struct LinkCodeView: View {
    let link: String

    var body: some View {
        if let modules = try? QR.encode(QR.segments(link)) {
            Canvas { context, size in
                let quiet = 4
                let cells = modules.count + 2 * quiet
                let module = min(size.width, size.height) / CGFloat(cells)
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                for (y, row) in modules.enumerated() {
                    for (x, dark) in row.enumerated() where dark {
                        // A hair over a module, so neighbours meet with no seam between them.
                        let r = CGRect(x: CGFloat(x + quiet) * module, y: CGFloat(y + quiet) * module, width: module + 0.5, height: module + 0.5)
                        context.fill(Path(r), with: .color(.black))
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 280)
            .accessibilityLabel("QR code of the group's join code")
        }
    }
}

/// A contact's code on a sheet of its own, for passing the same node on to someone else.
struct CodeSheet: View {
    let title: String
    let address: Address
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                QRCodeView(address: address)
                Text(Sharing.shortCode(address)).font(.title2.monospaced())
                Text("Someone else can scan this to add the same node.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: Sharing.link(address))
            }
            .padding()
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 320, minHeight: 420)
    }
}

#if os(iOS)
/// The camera, reading QR codes until one holds what `accepts` takes, a Tern address unless told
/// otherwise; then `found` is given the text, trimmed. `refusal` is said of any other code.
struct ScannerView: UIViewControllerRepresentable {
    var accepts: (String) -> Bool = { Sharing.read($0) != nil }
    var refusal = "That code does not hold a Tern address."
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.accepts = accepts
        controller.refusal = refusal
        controller.found = found
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var accepts: (String) -> Bool = { _ in false }
    var refusal = ""
    var found: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private let message = UILabel()
    private var done = false
    /// Gone from the screen: a camera allowed after that is not started.
    private var gone = false
    /// Starting and stopping block, so they run off the main thread, one after the other.
    private let queue = DispatchQueue(label: "org.ternmesh.tern.scanner")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        message.textColor = .white
        message.numberOfLines = 0
        message.textAlignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            message.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        say("Point the camera at the code on a Tern node or app.")

        AVCaptureDevice.requestAccess(for: .video) { allowed in
            DispatchQueue.main.async {
                if allowed { self.start() } else { self.say("Tern is not allowed to use the camera. Allow it in Settings, or paste the link instead.") }
            }
        }
    }

    private func start() {
        guard !gone else { return }
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input)
        else {
            say("This device has no camera Tern can use. Paste the link instead.")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        preview = layer
        let session = session
        queue.async { session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        gone = true
        let session = session
        queue.async { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done else { return }
        for case let code as AVMetadataMachineReadableCodeObject in objects {
            guard let text = code.stringValue else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if accepts(trimmed) {
                done = true
                found?(trimmed)
                return
            }
            say(refusal)
        }
    }

    private func say(_ text: String) { message.text = text }
}
#endif
