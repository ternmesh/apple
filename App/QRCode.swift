// An address's link as a QR code (draft/sharing.md), and on iPhone and iPad, the camera that reads
// one back. A Mac has no camera pointed at a node, so it takes a link or an address pasted in.

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
/// The camera, reading QR codes until one holds a Tern address; then [found] is given it.
struct ScannerView: UIViewControllerRepresentable {
    let found: (Address) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.found = found
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var found: ((Address) -> Void)?
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
            if let address = Sharing.read(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                done = true
                found?(address)
                return
            }
            say("That code does not hold a Tern address.")
        }
    }

    private func say(_ text: String) { message.text = text }
}
#endif
