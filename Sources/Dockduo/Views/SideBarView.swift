import SwiftUI

// La barra di lato (spec barra-di-lato §2-3, decisione 11: una sola, a sinistra o a destra): tre zone, in cima, al centro
// e in fondo, con i Dock in colonna nell'ordine salvato (spec dock-contenitori §1). I Dock (DockBoxView) sono in scala con la
// larghezza (SideLook) e, se non ci stanno, tutti insieme più piccoli (barFit). Le etichette che escono si misurano nello
// spazio "bar", che è tutto il pannello. ⌘-trascina (SideDrag) un Dock intero dentro la barra: fra le zone e nella zona.
// Lo Stato è un Dock come gli altri (DockBox.isStatus), e si restringe con loro. In modifica una sezione si trascina dentro
// un Dock, in un altro o fra i Dock, dove si apre il suo posto (DockDrop.sectionHover, sectionTarget).
struct SideBarView: View {
    let state: BarState
    let side: Side
    let place: SidePlace
    private let settings = Settings.shared
    private let drag = SideDrag.shared
    @State private var frames: [UUID: CGRect] = [:]   // i miei Dock nello spazio "bar" (⌘-trascina, rilasci)
    @State private var resting: [UUID: CGRect] = [:]   // Dock e loro voci senza un trascinamento sopra (rest)
    @State private var sectionFrames: [BarItem: CGRect] = [:]   // le sezioni, a riposo come `resting`
    @State private var held: (start: CGPoint, grab: CGFloat)?   // il ⌘-trascina partito qui: dove, e quanto dopo l'inizio del Dock lungo la barra
    @GestureState private var pressing = false   // il ⌘-trascina di questa barra è in corso (si azzera anche senza onEnded)
    @State private var icons = IconDragging()   // il trascina icone fra le pillole spazio (IconDrag.swift)

    var body: some View {
        let here = current
        // Il pannello spento (dopo un cambio sinistra/destra, a opacità 0) non disegna niente: nessun Dock.
        let docks = side == settings.barSide ? arranged(here) : []   // i Dock salvati o, mentre trascini su questo schermo, l'anteprima
        FittedZones(bar: side.axis.along(place.bar.size), scale: scale) {
            zone($0, docks, $1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Il rilascio di tutta la barra: l'unico, che non si muove mai sotto il puntatore (DockDropDelegate). Sulla barra
        // stessa, non su un fondo dietro i Dock: li contiene, quindi lo riceve anche sopra le loro icone, che prendono il
        // puntatore, e nei loro vuoti. Intanto, dal Finder, i Dock con Cartelle o Mensola vuote si fanno vedere
        // (DockDrop.overBar).
        // Durante un trascinamento la striscia non è trasparente: così lo prende tutta la barra (DockDrop.dragAround). In
        // modifica nemmeno: la barra è una superficie sola, e i clic sul "−" che sporge, sulle caselle vuote e sullo Stato
        // arrivano a lei (EditFrame); uno sui suoi vuoti non la chiude, come dentro il Centro di Controllo.
        .background(Color.black.opacity(DockDrop.shared.dragAround || Editing.shared.on ? 0.01 : 0))
        .contentShape(Rectangle())
        .onDrop(of: DockDrop.barTypes,
                delegate: DockDropDelegate(drop: .shared, display: place.display, target: { dropTarget($0, docks) },
                                           section: { sectionDropTarget($0, docks) }))
        // Le pillole che cambiano, i testi degli agenti sulle app, lo spostamento fra zone (anche l'anteprima: gli altri
        // fanno posto) e i Dock che si rimpiccioliscono.
        .animation(.smooth(duration: 0.3), value: state.reports)
        .animation(.smooth(duration: 0.3), value: QuotaCache.shared.renewed)
        .animation(.smooth(duration: 0.3), value: docks)
        // Il Dock trascinato è sparito a metà (tolto nelle Impostazioni, niente più da mostrare): il trascinamento finisce.
        // Il gesto resta di chi l'ha fatto partire (held): non ne riparte un altro.
        .onChange(of: here.map { shows($0.id) }) { _, shown in if shown == false { drag.current = nil } }
        // Un gesto interrotto senza onEnded: il suo trascinamento non resta appeso con la sua anteprima. Al giro
        // dopo, quando un rilascio vero avrebbe già chiuso lui.
        .onChange(of: pressing) { _, now in
            guard !now, let start = held?.start else { return }
            DispatchQueue.main.async {
                if drag.current?.start == onScreen(start) { drag.current = nil }
                held = nil
            }
        }
        .onChange(of: state.reports) { _, reports in icons.reportsChanged(reports) }
        .simultaneousGesture(rearrange)
        .coordinateSpace(name: "bar")
        .overlay(alignment: .topLeading) { IconDragCopy(drag: icons.drag) }   // l'icona trascinata
        .environment(\.barAxis, side.axis)
        .modifier(SideLook())
    }

    // La larghezza della barra in scala (38 = 1), senza restringere: i Dock prendono la loro da FittedZones.
    private var scale: CGFloat { settings.sideWidth / 38 }

    // Una zona alla scala dei Dock (`scale`, già ristretta): i suoi Dock in colonna (in basso in fila), a 6 l'uno dall'altro
    // come le pillole di prima. Un Dock senza niente da mostrare non disegna niente (DockBoxView), quindi non prende neanche il
    // distacco. In modifica, subito dopo l'ultimo Dock della barra (sotto, autore 27/10; in basso a destra), Fine: con la sua
    // zona, così si restringe con i Dock se non ci stanno; senza Dock, al centro. Una sezione in mano
    // che qui farebbe un Dock nuovo apre il suo posto fra i Dock: lei col margine di una capsula. Una barra dove non si vede
    // niente ha al centro la capsula vuota del Dock, da cliccare (emptyBarCapsuleShows).
    private func zone(_ zone: Zone, _ docks: [DockBox], _ scale: CGFloat) -> some View {
        let column = docks.filter { $0.zone == zone }
        let room: Int? = if case .newDock(zone, let at)? = sectionHover?.target { at } else { nil }
        let space = Color.clear.frame(side.axis, along: roomHeight(scale) + 14 * dockUnit * scale).transition(.opacity)
        let empty = zone == .middle && side == settings.barSide && emptyBarCapsuleShows(docks: docks, state: state, display: place.display)
        let doneZone = Zone.allCases.last { z in docks.contains { $0.zone == z } } ?? .middle
        return BarStack(spacing: 6) {
            ForEach(column) { box in
                if room == column.firstIndex(of: box) { space }
                dock(box, scale)
            }
            if let room, room >= column.count { space }
            if empty { EmptyBarCapsule(display: place.display, side: side).transition(.blurReplace) }
            if zone == doneZone, Editing.shared.on, side == settings.barSide { EditDoneButton().transition(.opacity) }
        }
        .animation(.smooth(duration: 0.3), value: Editing.shared.on)
        .animation(.smooth(duration: 0.3), value: room)
        .animation(.smooth(duration: 0.3), value: empty)
        // Il Dock trascinato sta sopra anche le altre zone, che si disegnano dopo la sua (la cima, il centro, il fondo).
        .zIndex(zoneZIndex(zone: zone, dragging: current?.id, in: docks))
    }

    // Un Dock: registra dove sta (solo se si vede) e dove le sue voci, e, se è quello trascinato, il suo scostamento
    // (inBar); se ha sopra un trascinamento, glielo dà. `scale`: quella della zona (già ristretta), per il posto che si apre.
    private func dock(_ box: DockBox, _ scale: CGFloat) -> some View {
        // Il trascina icone lungo la barra: le pillole spazio sono tratti di lei, lo spessore è quello della barra (in basso
        // l'altezza, che è la stessa misura).
        DockBoxView(box: box, state: state, side: side, icons: icons.hooks(state, thickness: settings.sideWidth, axis: side.axis),
                    onFrame: { frames[box.id] = $0; rest(box.id, $0) },
                    onTile: rest, onSection: { item, frame in if !frozen { sectionFrames[item] = frame } },
                    display: place.display, hover: hover?.dock == box.id ? hover : nil, room: room(in: box, scale))
            .inBar(grab: current?.id == box.id ? grab : nil,
                   pointer: alongBar(current?.point ?? .zero, side.axis).y - alongBar(place.bar, side.axis).minY, axis: side.axis)
    }

    // Il trascinamento sopra un Dock di questa barra, se c'è (DockDrop.hover è uno per tutte le barre).
    private var hover: DockHover? { DockDrop.shared.hover.flatMap { $0.display == place.display ? $0 : nil } }
    // La sezione in mano sopra questa barra, dove le si apre il posto (anche lui uno per tutte le barre).
    private var sectionHover: SectionHover? { DockDrop.shared.sectionHover.flatMap { $0.display == place.display ? $0 : nil } }

    // Una cornice a riposo. Mentre su questa barra un trascinamento apre un posto restano tutte quelle di prima: il Dock si
    // allunga, la zona lo ricentra e sposta i vicini, e deciderci sopra rifarebbe il giro che faceva tremare il Dock (25/10).
    // Una vista che se ne va (.null) se ne va comunque.
    private func rest(_ id: UUID, _ frame: CGRect) { if !frozen || frame.isNull { resting[id] = frame } }
    private var frozen: Bool { hover != nil || sectionHover != nil }

    // Il posto che la sezione in mano apre dentro quel Dock, se cadrebbe lì.
    private func room(in box: DockBox, _ scale: CGFloat) -> (at: Int, height: CGFloat)? {
        guard case .into(box.id, let at)? = sectionHover?.target else { return nil }
        return (at, roomHeight(scale))
    }
    // Lungo quanto lei, a riposo; dalla galleria (in nessun Dock) quanto una casella del Dock alla scala della zona (`scale`,
    // ristretta coi Dock se la barra è piena).
    private func roomHeight(_ scale: CGFloat) -> CGFloat {
        DockDrop.shared.movingSection.flatMap { sectionFrames[$0].map { side.axis.along($0.size) } } ?? dockIcon * scale
    }

    // Dove cadrebbe la sezione in mano (sectionTarget), sulle cornici a riposo dei Dock e delle loro sezioni; le zone sono i
    // terzi della barra, come per il ⌘-trascina (sideDropTarget). Tutto girato lungo la barra (alongBar).
    private func sectionDropTarget(_ p: CGPoint, _ docks: [DockBox]) -> SectionTarget? {
        let axis = side.axis, bar = alongBar(CGRect(origin: .zero, size: place.bar.size), axis)
        let third = bar.height / 3
        let zones = Dictionary(uniqueKeysWithValues: Zone.allCases.enumerated().map {
            ($1, CGRect(x: 0, y: CGFloat($0) * third, width: bar.width, height: third))
        })
        return sectionTarget(at: alongBar(p, axis).y,
                             docks: docks.map { box in (box, alongBar(resting[box.id] ?? .null, axis),
                                                        box.sections.map { alongBar(sectionFrames[$0] ?? .null, axis) }) },
                             zones: zones)
    }

    // Il Dock sotto un trascinamento e dove ci cadrebbe un rilascio (DockDropDelegate): fra quelli che lo prendono
    // (dockTakes), sulle cornici a riposo (hoveredDock, dropSpot), girate lungo la barra (alongBar).
    private func dropTarget(_ p: CGPoint, _ docks: [DockBox]) -> (box: DockBox, spot: DockSpot)? {
        let drop = DockDrop.shared, taking = docks.filter { dockTakes($0, from: drop.source) }, axis = side.axis
        let q = alongBar(p, axis), rest = resting.mapValues { alongBar($0, axis) }
        guard let id = hoveredDock(at: q, docks: taking.map(\.id), resting: rest, current: frames.mapValues { alongBar($0, axis) },
                                   hovered: hover?.dock),
              let box = taking.first(where: { $0.id == id }) else { return nil }
        return (box, settings.dropSpot(in: box, y: q.y, resting: rest, moving: drop.moving))
    }

    // Un Dock che si può prendere col ⌘: c'è ancora e una sua sezione si vede (barItemShows). Quello che DockBoxView mostra
    // in più durante un trascinamento dal Finder qui non conta: col ⌘-trascina non ce n'è.
    private func shows(_ id: UUID) -> Bool {
        settings.docks.contains { box in box.id == id && box.sections.contains { barItemShows($0, state: state) } }
    }

    // Il ⌘-trascina di questo schermo, se c'è.
    private var current: SideDrag.Current? { drag.current.flatMap { $0.display == place.display ? $0 : nil } }

    // Quanto dopo il suo inizio hai preso il Dock, se quel ⌘-trascina è il suo (lo stesso punto di presa: un `held` rimasto da un
    // gesto interrotto non sposta un trascinamento nuovo).
    private var grab: CGFloat? { held.flatMap { h in current?.start == onScreen(h.start) ? h.grab : nil } }

    // Un punto dello spazio "bar" nelle coordinate dall'alto dello schermo.
    private func onScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + place.bar.minX, y: p.y + place.bar.minY) }

    // Dove cadrebbe il Dock che trascini (sideDropTarget fra i Dock di ogni zona), sulle cornici di quando hai cominciato;
    // chi nel frattempo è sparito non conta. Girato lungo la barra (alongBar): in basso i terzi da sinistra a destra.
    private func target(_ c: SideDrag.Current) -> (zone: Zone, index: Int) {
        let axis = side.axis, bar = alongBar(place.bar, axis)
        return sideDropTarget(at: alongBar(c.point, axis), barTop: bar.minY, barBottom: bar.maxY, dragging: c.id,
                              columns: Dictionary(uniqueKeysWithValues: Zone.allCases.map { ($0, settings.docks(in: $0).map(\.id)) }),
                              frames: c.frames.filter { shows($0.key) }.mapValues { alongBar($0, axis) })
    }

    // I Dock come si vedono: quelli salvati o, mentre trascini, come saranno al rilascio.
    private func arranged(_ c: SideDrag.Current?) -> [DockBox] {
        guard let c else { return settings.docks }
        let t = target(c)
        return dockMoved(c.id, to: t.zone, index: t.index, docks: settings.docks)
    }

    // ⌘-trascina: un gesto per la barra, che all'inizio prende il Dock sotto il puntatore e sopravvive all'anteprima che lo
    // porta in un'altra zona. Fuori dal pannello AppKit manda ancora qui il trascinamento (alla finestra del clic): conta
    // solo la posizione lungo la barra.
    private var rearrange: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("bar")).modifiers(.command)
            .updating($pressing) { _, on, _ in on = true }
            .onChanged { v in
                if held?.start == v.startLocation { drag.current?.point = onScreen(v.location); return }
                // Sul Dock, non accanto: tutta la barra prende il punto (contentShape, per il suo rilascio).
                guard let hit = frames.first(where: { shows($0.key) && $0.value.contains(v.startLocation) }) else { return }
                held = (v.startLocation, alongBar(v.startLocation, side.axis).y - alongBar(hit.value, side.axis).minY)
                drag.current = SideDrag.Current(id: hit.key, display: place.display, start: onScreen(v.startLocation), point: onScreen(v.location),
                                                frames: frames.mapValues { $0.offsetBy(dx: place.bar.minX, dy: place.bar.minY) })
            }
            .onEnded { v in
                defer { held = nil }
                guard held?.start == v.startLocation, var c = drag.current else { return }   // nessuno o già finito (sparito)
                c.point = onScreen(v.location)
                let t = target(c)
                // Il rilascio salva l'anteprima; lo scostamento si azzera nella stessa animazione: il Dock scivola dal
                // puntatore al suo posto, che è già quello. Pannello passato a un altro schermo a metà: solo fine.
                withAnimation(.smooth(duration: 0.3)) {
                    drag.current = nil
                    if c.display == place.display { settings.moveDock(c.id, to: t.zone, index: t.index) }
                }
            }
    }
}

// Un Dock nella barra, come lo fanno SideBarView e le prove: quello trascinato col ⌘ resta sotto il puntatore anche quando
// l'anteprima gli cambia posto o zona (lo scostamento letto mentre si disegna, visualEffect). `grab`: quanto dopo il suo
// inizio l'hai preso, se è lui; `pointer`: il puntatore nello spazio "bar". Tutti e due lungo la barra (alongBar, `axis`):
// lo scostamento è solo lungo di lei. Niente qui aggiunge una vista: un Dock senza niente da mostrare resta senza, e la
// zona non gli dà un distacco.
extension View {
    func inBar(grab: CGFloat?, pointer: CGFloat, axis: BarAxis) -> some View {
        visualEffect { effect, proxy in
            let along = grab.map { pointer - $0 - alongBar(proxy.frame(in: .named("bar")), axis).minY } ?? 0
            let shift = alongBar(CGPoint(x: 0, y: along), axis)
            return effect.offset(x: shift.x, y: shift.y)
        }
            .zIndex(grab == nil ? 0 : 1)
            // Quello trascinato cambia posto senza animazione (resta incollato al puntatore); gli altri scivolano.
            .transaction { if grab != nil { $0.animation = nil } }
    }
}

// Le tre zone con una scala sola per tutti i Dock quando la barra (`bar`, la sua lunghezza) non li tiene (spec
// dock-contenitori §5). Le misure sono lungo la barra (barAxis): altezze di lato, larghezze in basso. Ogni
// zona si misura alla scala con cui si è disegnata e si riporta a scala 1: così l'altezza naturale quasi non dipende dalla
// scala di adesso, e barFit la dà giusta per il disegno dopo (per un disegno i Dock hanno la grandezza di prima). Quasi: il
// testo cresce a passi, quindi la scala scende subito e risale solo fin dove ci si starebbe anche col margine del testo
// (fitRiseMargin): ogni giro si ferma dentro la barra. `zone` disegna una zona alla scala ristretta; `scale` è quella della
// larghezza della barra, senza restringere.
struct FittedZones<Content: View>: View {
    let bar: CGFloat
    let scale: CGFloat
    @ViewBuilder let zone: (Zone, CGFloat) -> Content
    @Environment(\.barAxis) private var axis
    @State private var heights: [Zone: CGFloat] = [:]   // a scala 1, lungo la barra
    @State private var fit: CGFloat = 1

    var body: some View {
        let drawn = max(fit, 0.001), fitted = scale * fit   // la scala di questo disegno, quella delle misure che darà
        let axis = self.axis
        SideZones(gap: 6 * fitted, axis: axis) {
            ForEach(Zone.allCases, id: \.self) { z in
                zone(z, fitted).onGeometryChange(for: CGFloat.self) { axis.along($0.size) } action: { heights[z] = $0 / drawn }
            }
        }
        .environment(\.barScale, fitted)
        .onChange(of: [down, up]) { _, new in if new[0] < fit { fit = new[0] } else if new[1] > fit { fit = new[1] } }
        .animation(.smooth(duration: 0.3), value: fit)
    }

    private var natural: CGFloat { heights.values.reduce(0, +) + 2 * 6 * scale }
    private var down: CGFloat { barFit(bar: bar, natural: natural) }   // sotto questa si sborda
    private var up: CGFloat { barFit(bar: bar / (1 + fitRiseMargin), natural: natural) }
}

// Il testo della barra cresce a passi di un punto: rimisurata a un'altra scala, l'altezza a scala 1 cambia fino a circa il
// 2 % (una ventina di testi a barra 1000).
// shortcut: con più di una ventina di testi nella barra il margine non basta e la scala può tornare a ballare; se capita,
// ricordare la scala più bassa che sbordava e non risalirci finché il contenuto non cambia.
private let fitRiseMargin: CGFloat = 0.02

// Le tre zone (cima, mezzo, fondo) alla loro lunghezza naturale, al centro attraverso la barra, dove dice sideZoneTops: mai
// una sopra l'altra. In basso la cima è a sinistra e il fondo a destra.
private struct SideZones: Layout {
    let gap: CGFloat
    let axis: BarAxis

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let vertical = axis == .vertical
        func proposed(_ along: CGFloat?) -> ProposedViewSize {
            vertical ? ProposedViewSize(width: bounds.width, height: along) : ProposedViewSize(width: along, height: bounds.height)
        }
        let h = subviews.map { axis.along($0.sizeThatFits(proposed(nil))) }
        let tops = sideZoneTops(bar: axis.along(bounds.size), top: h[0], middle: h[1], bottom: h[2], gap: gap)
        for (i, t) in [0, tops.middle, tops.bottom].enumerated() {
            let at = vertical ? CGPoint(x: bounds.midX, y: bounds.minY + t) : CGPoint(x: bounds.minX + t, y: bounds.midY)
            subviews[i].place(at: at, anchor: vertical ? .top : .leading, proposal: proposed(h[i]))
        }
    }
}

// L'aspetto della barra di lato: il chiaro o lo scuro del Mac (spec dock-degli-agenti §5), le pillole in colonna e in scala
// con la larghezza (38 = scala 1, la misura delle pillole di Siigil). Anche per il pannello delle etichette, che esce dalla
// barra.
struct SideLook: ViewModifier {
    @Environment(\.colorScheme) private var scheme   // chiaro/scuro del Mac: il pannello non forza l'aspetto

    func body(content: Content) -> some View {
        let palette = Dockduo.palette(dark: scheme == .dark)
        content
            .foregroundStyle(palette?.text ?? .white)
            .environment(\.barScale, Settings.shared.sideWidth / 38)
            .environment(\.palette, palette)
            .animation(.smooth(duration: 0.3), value: palette)
    }
}

// La zona che contiene il Dock trascinato sta sopra le altre: zIndex dentro la zona non basta, le zone sono viste sorelle.
func zoneZIndex(zone: Zone, dragging: UUID?, in docks: [DockBox]) -> Double {
    docks.contains { $0.id == dragging && $0.zone == zone } ? 1 : 0
}
