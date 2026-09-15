import UIKit

/// One screen: the view, and a small settings sheet for the bundle URL, the UDP port and the pod angle.
final class ViewController: UIViewController {
    let render = RenderView(frame: .zero)
    let status = UILabel()
    var receiver: LinkReceiver?
    let defaults = UserDefaults.standard

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        render.frame = view.bounds; render.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(render)
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular); status.textColor = .white
        status.frame = CGRect(x: 12, y: 40, width: 800, height: 20); status.autoresizingMask = [.flexibleWidth]
        view.addSubview(status)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showSettings)))
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateStatus() }
        applySettings()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // a saved URL is fetched on every launch (the cached copy in Documents only bridges the gap); an unconfigured app asks
        if let url = defaults.string(forKey: "bundleURL"), !url.isEmpty { fetchBundle(url) } else if render.world == nil { showSettings() }
    }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }

    func updateStatus() {
        let s = render.lastStats
        if let p = s.pose { status.text = String(format: "track %d  pos %d %d %d  cars %d  faces %d  hz %d/%d %@  packets %d  port %d  yaw %.0f", s.track, p.x, p.y, p.z, p.cars.count, s.faces, s.horizonStrips, s.horizonSlices, s.horizonNote, receiver?.state.packets ?? 0, defaults.integer(forKey: "port"), defaults.double(forKey: "yaw")) }
        else { status.text = render.world == nil ? "tap for settings: bundle URL, port, pod angle" : "waiting for the link on udp \(defaults.integer(forKey: "port"))... packets \(receiver?.state.packets ?? 0)" }
    }

    func applySettings() {
        let port = defaults.integer(forKey: "port") == 0 ? 5000 : defaults.integer(forKey: "port")
        var o = RenderOptions(); o.yawDegrees = defaults.double(forKey: "yaw"); o.pitchDegrees = defaults.double(forKey: "pitch")
        render.renderer = FrameRenderer(options: o)
        if receiver == nil || defaults.integer(forKey: "port") != port {
            receiver?.stop()
            let r = LinkReceiver(source: UDPSource(port: UInt16(port))); r.start()
            receiver = r; render.state = r.state
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("world.json")
        if render.world == nil, let w = try? World.load(docs) { render.world = w }
    }

    @objc func showSettings() {
        let a = UIAlertController(title: "RDPView", message: "Bundle URL (http://mac:8000/world.json), UDP port, pod yaw (53 right, -53 left, 0 forward)", preferredStyle: .alert)
        a.addTextField { $0.placeholder = "http://192.168.1.10:8000/world.json"; $0.text = self.defaults.string(forKey: "bundleURL"); $0.keyboardType = .URL; $0.autocapitalizationType = .none }
        a.addTextField { $0.placeholder = "5000"; $0.text = self.defaults.integer(forKey: "port") == 0 ? "5000" : String(self.defaults.integer(forKey: "port")); $0.keyboardType = .numberPad }
        a.addTextField { $0.placeholder = "0"; $0.text = String(self.defaults.double(forKey: "yaw")); $0.keyboardType = .numbersAndPunctuation }
        a.addAction(UIAlertAction(title: "Apply", style: .default) { _ in
            let url = a.textFields![0].text ?? "", port = Int(a.textFields![1].text ?? "") ?? 5000, yaw = Double(a.textFields![2].text ?? "") ?? 0
            self.defaults.set(url, forKey: "bundleURL"); self.defaults.set(port, forKey: "port"); self.defaults.set(yaw, forKey: "yaw")
            self.fetchBundle(url)
            self.applySettings()
        })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(a, animated: true)
    }

    func fetchBundle(_ urlString: String) {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return }
        status.text = "fetching bundle..."
        URLSession.shared.dataTask(with: url) { data, _, err in
            DispatchQueue.main.async {
                guard let data = data else { self.status.text = "bundle fetch failed: \(err?.localizedDescription ?? "?")"; return }
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("world.json")
                try? data.write(to: docs)
                if let w = try? World.load(docs) { self.render.world = w; self.status.text = "bundle loaded: \(w.objects.count) objects" }
                else { self.status.text = "bundle did not decode" }
            }
        }.resume()
    }
}
