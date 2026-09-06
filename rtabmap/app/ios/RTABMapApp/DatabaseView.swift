/**
 * Copyright (c) 2017 Razeware LLC
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
 * distribute, sublicense, create a derivative work, and/or sell copies of the
 * Software in any work that is designed, intended, or marketed for pedagogical or
 * instructional purposes related to programming, coding, application development,
 * or information technology.  Permission for such use, copying, modification,
 * merger, publication, distribution, sublicensing, creation of derivative works,
 * or sale is expressly withheld.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

import UIKit

enum MissionTheme {
    static let ink = UIColor(red: 5/255, green: 7/255, blue: 10/255, alpha: 1)
    static let text = UIColor(red: 243/255, green: 245/255, blue: 244/255, alpha: 1)
    static let muted = UIColor(red: 243/255, green: 245/255, blue: 244/255, alpha: 0.58)
    static let orange = UIColor(red: 227/255, green: 148/255, blue: 42/255, alpha: 1)
    static let go = UIColor(red: 71/255, green: 255/255, blue: 81/255, alpha: 1)
    static let forest = UIColor(red: 107/255, green: 138/255, blue: 90/255, alpha: 1)
    static let panel = UIColor(red: 16/255, green: 19/255, blue: 24/255, alpha: 0.92)
    static let line = UIColor(red: 243/255, green: 245/255, blue: 244/255, alpha: 0.16)
}

enum MissionIcons {
    enum Glyph {
        case library, menu, file, settings, view, stop, record, addMeasure, removeMeasure, teleport, measure, export, close
    }

    static func image(_ glyph: Glyph, pointSize: CGFloat = 22, color: UIColor = MissionTheme.text) -> UIImage {
        let size = CGSize(width: pointSize, height: pointSize)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setStrokeColor(color.cgColor)
            cg.setFillColor(color.cgColor)
            cg.setLineWidth(max(1.5, pointSize * 0.07))
            cg.setLineCap(.square)
            cg.setLineJoin(.miter)
            let inset = pointSize * 0.1
            draw(glyph, in: CGRect(x: inset, y: inset, width: pointSize - inset * 2, height: pointSize - inset * 2), ctx: cg)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    private static func draw(_ glyph: Glyph, in r: CGRect, ctx: CGContext) {
        switch glyph {
        case .library:
            let step = r.height * 0.28
            let shift = r.width * 0.07
            for i in 0..<3 {
                let t = CGFloat(i)
                let rect = CGRect(
                    x: r.minX + shift * (2 - t),
                    y: r.minY + step * t,
                    width: r.width * 0.78,
                    height: r.height * 0.22)
                ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 1.5).cgPath)
            }
            ctx.strokePath()

        case .menu:
            let cell = r.width * 0.34
            let gap = r.width * 0.16
            for row in 0..<2 {
                for col in 0..<2 {
                    let rect = CGRect(
                        x: r.minX + CGFloat(col) * (cell + gap),
                        y: r.minY + CGFloat(row) * (cell + gap),
                        width: cell,
                        height: cell)
                    ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 1.8).cgPath)
                }
            }
            ctx.fillPath()

        case .file:
            let page = CGRect(x: r.minX + r.width * 0.12, y: r.minY, width: r.width * 0.72, height: r.height)
            ctx.addPath(UIBezierPath(roundedRect: page, cornerRadius: 2).cgPath)
            ctx.strokePath()
            let fold = r.width * 0.28
            ctx.move(to: CGPoint(x: page.maxX - fold, y: page.minY))
            ctx.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY + fold))
            ctx.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
            ctx.strokePath()
            let lineY: [CGFloat] = [0.48, 0.64, 0.80]
            for t in lineY {
                ctx.move(to: CGPoint(x: page.minX + page.width * 0.18, y: page.minY + page.height * t))
                ctx.addLine(to: CGPoint(x: page.maxX - page.width * 0.18, y: page.minY + page.height * t))
            }
            ctx.strokePath()

        case .settings:
            let midY = [r.minY + r.height * 0.2, r.midY, r.maxY - r.height * 0.2]
            let knobs: [CGFloat] = [0.32, 0.68, 0.5]
            for i in 0..<3 {
                ctx.move(to: CGPoint(x: r.minX, y: midY[i]))
                ctx.addLine(to: CGPoint(x: r.maxX, y: midY[i]))
                ctx.strokePath()
                let knob = CGRect(x: r.minX + r.width * knobs[i] - r.width * 0.1, y: midY[i] - r.height * 0.1, width: r.width * 0.2, height: r.height * 0.2)
                ctx.addPath(UIBezierPath(roundedRect: knob, cornerRadius: 2).cgPath)
                ctx.fillPath()
            }

        case .view:
            let midX = r.midX
            let top = r.minY
            let mid = r.minY + r.height * 0.36
            let bottom = r.maxY
            ctx.move(to: CGPoint(x: midX, y: top))
            ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.22))
            ctx.addLine(to: CGPoint(x: midX, y: mid))
            ctx.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.22))
            ctx.closePath()
            ctx.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.22))
            ctx.addLine(to: CGPoint(x: midX, y: mid))
            ctx.addLine(to: CGPoint(x: midX, y: bottom))
            ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY - r.height * 0.22))
            ctx.closePath()
            ctx.move(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.22))
            ctx.addLine(to: CGPoint(x: midX, y: mid))
            ctx.addLine(to: CGPoint(x: midX, y: bottom))
            ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.22))
            ctx.closePath()
            ctx.strokePath()

        case .stop:
            let pad = r.width * 0.16
            let rect = r.insetBy(dx: pad, dy: pad)
            ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 3).cgPath)
            ctx.fillPath()

        case .record:
            ctx.addEllipse(in: r.insetBy(dx: r.width * 0.18, dy: r.height * 0.18))
            ctx.fillPath()

        case .addMeasure:
            let ring = r.insetBy(dx: r.width * 0.04, dy: r.height * 0.04)
            ctx.addEllipse(in: ring)
            ctx.strokePath()
            let arm = r.width * 0.28
            ctx.move(to: CGPoint(x: r.midX - arm, y: r.midY))
            ctx.addLine(to: CGPoint(x: r.midX + arm, y: r.midY))
            ctx.move(to: CGPoint(x: r.midX, y: r.midY - arm))
            ctx.addLine(to: CGPoint(x: r.midX, y: r.midY + arm))
            ctx.strokePath()

        case .removeMeasure:
            let ring = r.insetBy(dx: r.width * 0.04, dy: r.height * 0.04)
            ctx.addEllipse(in: ring)
            ctx.strokePath()
            let arm = r.width * 0.26
            ctx.move(to: CGPoint(x: r.midX - arm, y: r.midY))
            ctx.addLine(to: CGPoint(x: r.midX + arm, y: r.midY))
            ctx.strokePath()

        case .teleport:
            ctx.move(to: CGPoint(x: r.minX + r.width * 0.12, y: r.maxY - r.height * 0.08))
            ctx.addLine(to: CGPoint(x: r.maxX - r.width * 0.12, y: r.maxY - r.height * 0.08))
            ctx.move(to: CGPoint(x: r.midX, y: r.maxY - r.height * 0.08))
            ctx.addLine(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.08))
            ctx.move(to: CGPoint(x: r.midX - r.width * 0.28, y: r.minY + r.height * 0.36))
            ctx.addLine(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.08))
            ctx.addLine(to: CGPoint(x: r.midX + r.width * 0.28, y: r.minY + r.height * 0.36))
            ctx.strokePath()

        case .measure:
            ctx.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.18))
            ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY - r.height * 0.18))
            ctx.move(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.18))
            ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.18))
            ctx.move(to: CGPoint(x: r.minX, y: r.midY))
            ctx.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            ctx.strokePath()
            let tick = r.width * 0.14
            ctx.move(to: CGPoint(x: r.midX - tick, y: r.midY - tick))
            ctx.addLine(to: CGPoint(x: r.midX, y: r.midY))
            ctx.addLine(to: CGPoint(x: r.midX - tick, y: r.midY + tick))
            ctx.strokePath()

        case .export:
            let box = CGRect(x: r.minX, y: r.minY + r.height * 0.38, width: r.width, height: r.height * 0.62)
            ctx.addPath(UIBezierPath(roundedRect: box, cornerRadius: 2).cgPath)
            ctx.strokePath()
            ctx.move(to: CGPoint(x: r.midX, y: r.maxY - r.height * 0.12))
            ctx.addLine(to: CGPoint(x: r.midX, y: r.minY))
            ctx.move(to: CGPoint(x: r.midX - r.width * 0.28, y: r.minY + r.height * 0.28))
            ctx.addLine(to: CGPoint(x: r.midX, y: r.minY))
            ctx.addLine(to: CGPoint(x: r.midX + r.width * 0.28, y: r.minY + r.height * 0.28))
            ctx.strokePath()

        case .close:
            ctx.move(to: CGPoint(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.12))
            ctx.addLine(to: CGPoint(x: r.maxX - r.width * 0.12, y: r.maxY - r.height * 0.12))
            ctx.move(to: CGPoint(x: r.maxX - r.width * 0.12, y: r.minY + r.height * 0.12))
            ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.12, y: r.maxY - r.height * 0.12))
            ctx.strokePath()
        }
    }
}

protocol DatabaseViewDelegate: AnyObject {
    func databaseShared(databaseURL: URL)
    func databaseRenamed(databaseURL: URL)
    func databaseDeleted(databaseURL: URL)
}

final class LibraryViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let databases: [URL]
    private var selectedIndex: Int
    weak var databaseDelegate: DatabaseViewDelegate?
    var onOpen: ((Int) -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)

    init(databases: [URL], selectedIndex: Int) {
        self.databases = databases
        self.selectedIndex = databases.isEmpty ? 0 : min(max(selectedIndex, 0), databases.count - 1)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = databases.count == 1 ? "1 scan" : "\(databases.count) scans"
        view.backgroundColor = MissionTheme.ink
        overrideUserInterfaceStyle = .dark

        navigationController?.navigationBar.barStyle = .black
        navigationController?.navigationBar.barTintColor = MissionTheme.ink
        navigationController?.navigationBar.isTranslucent = false
        navigationController?.navigationBar.titleTextAttributes = [
            .foregroundColor: MissionTheme.text,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Close",
            style: .plain,
            target: self,
            action: #selector(closeTapped))
        navigationItem.leftBarButtonItem?.tintColor = MissionTheme.text

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = MissionTheme.ink
        tableView.separatorColor = MissionTheme.line
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 124, bottom: 0, right: 0)
        tableView.rowHeight = 92
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(LibraryCell.self, forCellReuseIdentifier: LibraryCell.reuseId)
        tableView.tableFooterView = UIView()
        tableView.indicatorStyle = .white
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return databases.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LibraryCell.reuseId, for: indexPath) as! LibraryCell
        cell.configure(url: databases[indexPath.row], selected: indexPath.row == selectedIndex)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedIndex = indexPath.row
        tableView.reloadData()
        dismiss(animated: true) {
            self.onOpen?(indexPath.row)
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let url = databases[indexPath.row]
        let share = UIContextualAction(style: .normal, title: "Share") { [weak self] _, _, done in
            self?.databaseDelegate?.databaseShared(databaseURL: url)
            done(true)
        }
        let rename = UIContextualAction(style: .normal, title: "Rename") { [weak self] _, _, done in
            self?.databaseDelegate?.databaseRenamed(databaseURL: url)
            done(true)
        }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.databaseDelegate?.databaseDeleted(databaseURL: url)
            done(true)
        }
        share.backgroundColor = MissionTheme.forest
        rename.backgroundColor = MissionTheme.orange
        return UISwipeActionsConfiguration(actions: [delete, rename, share])
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let url = databases[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                self?.databaseDelegate?.databaseShared(databaseURL: url)
            }
            let rename = UIAction(title: "Rename", image: UIImage(systemName: "square.and.pencil")) { _ in
                self?.databaseDelegate?.databaseRenamed(databaseURL: url)
            }
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self?.databaseDelegate?.databaseDeleted(databaseURL: url)
            }
            return UIMenu(title: "", children: [share, rename, delete])
        }
    }
}

private final class LibraryCell: UITableViewCell {
    static let reuseId = "LibraryCell"

    private let thumb = UIImageView()
    private let nameLabel = UILabel()
    private let metaLabel = UILabel()
    private var loadPath: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = MissionTheme.ink
        contentView.backgroundColor = MissionTheme.ink
        selectedBackgroundView = UIView()
        selectedBackgroundView?.backgroundColor = MissionTheme.orange.withAlphaComponent(0.14)

        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 8
        thumb.backgroundColor = UIColor(white: 1, alpha: 0.06)
        thumb.layer.borderWidth = 1
        thumb.layer.borderColor = MissionTheme.line.cgColor

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        nameLabel.textColor = MissionTheme.text
        nameLabel.lineBreakMode = .byTruncatingMiddle

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        metaLabel.textColor = MissionTheme.muted

        contentView.addSubview(thumb)
        contentView.addSubview(nameLabel)
        contentView.addSubview(metaLabel)

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            thumb.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 96),
            thumb.heightAnchor.constraint(equalToConstant: 64),
            nameLabel.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -2),
            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 2)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(url: URL, selected: Bool) {
        nameLabel.text = url.deletingPathExtension().lastPathComponent
        var meta = url.fileSizeString
        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .short
            meta += "  ·  " + rel.localizedString(for: date, relativeTo: Date())
        }
        metaLabel.text = meta
        accessoryType = selected ? .checkmark : .none
        tintColor = MissionTheme.orange

        loadPath = url.path
        if let image = ViewController.previewImages[url.path] {
            thumb.image = image
        } else {
            thumb.image = nil
            let path = url.path
            DispatchQueue.global().async {
                let image = getPreviewImage(databasePath: path)
                DispatchQueue.main.async {
                    ViewController.previewImages[path] = image
                    if self.loadPath == path {
                        self.thumb.image = image
                    }
                }
            }
        }
    }
}

class DatabaseView: UIView {

  private var coverImageView: UIImageView!
  private var indicatorView: UIActivityIndicatorView!
  private var valueObservation: NSKeyValueObservation!
  private var textLabel: UILabel!
  private var metaLabel: UILabel!
  private var databaseURL: URL!
  public weak var delegate: DatabaseViewDelegate!

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    commonInit(databasePath: "NA")
  }

    init(frame: CGRect, databaseURL: URL) {
        super.init(frame: frame)
        self.databaseURL = databaseURL
        commonInit(databasePath: databaseURL.path)
        if let image = ViewController.previewImages[databaseURL.path]
        {
            self.coverImageView.image = image
        }
        else
        {
            DispatchQueue.global().async {
                let downloadedImage = getPreviewImage(databasePath: databaseURL.path)
                DispatchQueue.main.async {
                    self.coverImageView.image = downloadedImage
                    ViewController.previewImages[databaseURL.path] = downloadedImage
                }
            }
        }
    }

  private func commonInit(databasePath: String) {
    backgroundColor = MissionTheme.ink
    layer.borderWidth = 1
    layer.borderColor = MissionTheme.line.cgColor
    layer.cornerRadius = 10
    clipsToBounds = true
    coverImageView = UIImageView()
    coverImageView.translatesAutoresizingMaskIntoConstraints = false
    coverImageView.contentMode = .scaleAspectFill
    coverImageView.clipsToBounds = true

    valueObservation = coverImageView.observe(\.image, options: [.new]) { [unowned self] observed, change in
      if change.newValue is UIImage {
        self.indicatorView.stopAnimating()
      }
    }

    let url = URL(fileURLWithPath: databasePath)
    textLabel = UILabel()
    textLabel.numberOfLines = 1
    textLabel.text = url.deletingPathExtension().lastPathComponent
    textLabel.textColor = MissionTheme.text
    textLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    textLabel.textAlignment = .left
    textLabel.lineBreakMode = .byTruncatingMiddle

    metaLabel = UILabel()
    metaLabel.numberOfLines = 2
    var meta = url.path == "NA" ? "" : url.fileSizeString
    if url.path != "NA", let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
        meta += "\n" + date.getFormattedDate(format: "MMM d, yyyy  HH:mm")
    }
    metaLabel.text = meta
    metaLabel.textColor = MissionTheme.muted
    metaLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
    metaLabel.textAlignment = .left

    let labels = UIStackView(arrangedSubviews: [textLabel, metaLabel])
    labels.axis = .vertical
    labels.alignment = .leading
    labels.spacing = 4

    let stackView = UIStackView()
    stackView.axis = .horizontal
    stackView.distribution = .fill
    stackView.alignment = .center
    stackView.spacing = 10
    stackView.addArrangedSubview(coverImageView)
    stackView.addArrangedSubview(labels)
    stackView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stackView)

    indicatorView = UIActivityIndicatorView()
    indicatorView.translatesAutoresizingMaskIntoConstraints = false
    indicatorView.style = .large
    indicatorView.color = MissionTheme.text
    indicatorView.startAnimating()
    addSubview(indicatorView)

    NSLayoutConstraint.activate([
      stackView.leftAnchor.constraint(equalTo: self.leftAnchor, constant: 8),
      stackView.rightAnchor.constraint(equalTo: self.rightAnchor, constant: -8),
      stackView.topAnchor.constraint(equalTo: self.topAnchor, constant: 8),
      stackView.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -8),
      coverImageView.widthAnchor.constraint(equalToConstant: 160),
      indicatorView.centerXAnchor.constraint(equalTo: coverImageView.centerXAnchor),
      indicatorView.centerYAnchor.constraint(equalTo: coverImageView.centerYAnchor)
      ])

    let interaction = UIContextMenuInteraction(delegate: self)
    self.addInteraction(interaction)
  }

    func highlightDatabase(_ didHighlightView: Bool) {
      if didHighlightView == true {
        backgroundColor = MissionTheme.orange.withAlphaComponent(0.16)
        layer.borderColor = MissionTheme.orange.cgColor
      } else {
        backgroundColor = MissionTheme.ink
        layer.borderColor = MissionTheme.line.cgColor
      }
    }
}

extension URL {
    var attributes: [FileAttributeKey : Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: path)
        } catch let error as NSError {
            print("FileAttribute error: \(error)")
        }
        return nil
    }

    var fileSize: UInt64 {
        return attributes?[.size] as? UInt64 ?? UInt64(0)
    }

    var fileSizeString: String {
        return ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    var creationDate: Date? {
        return attributes?[.creationDate] as? Date
    }
}

extension DatabaseView: UIContextMenuInteractionDelegate {

      func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { suggestedActions in

            let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { action in
                self.delegate?.databaseShared(databaseURL: self.databaseURL)
            }

            let rename = UIAction(title: "Rename", image: UIImage(systemName: "square.and.pencil")) { action in
                self.delegate?.databaseRenamed(databaseURL: self.databaseURL)
            }

            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { action in
                self.delegate?.databaseDeleted(databaseURL: self.databaseURL)
            }

            return UIMenu(title: "", children: [share, rename, delete])
        }
    }
}
