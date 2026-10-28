import AppKit
import SwiftUI

// Il Benvenuto (spec benvenuto §1 e §3): tre passi nello stesso Form — impostazioni base, permessi, agenti AI — uno
// alla volta con `step`. Ogni riga ha un titolo che dice da solo a cosa serve e, a destra, il segno verde o i
// pulsanti; sotto, in rosso, l'errore dell'ultima azione. Le righe che non servono non compaiono. Lo stato si rilegge
// dopo ogni pulsante (SetupModel.refresh); quando torna key lo fa la finestra, windowDidBecomeKey.
struct WelcomeView: View {
    let model: SetupModel
    let close: () -> Void
    private let settings = Settings.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                Text("Welcome to dockduo").font(.title.bold())
                Text("A few things to set up. You'll find this again in Settings › Setup.").foregroundStyle(.secondary)
            }
            .padding(.top, 28).padding(.bottom, 4)   // sopra ci sono i semafori della finestra
            Form {
                Section {
                    switch model.step {
                    case 0:
                        if !model.isInApplications {
                            row("folder", "dockduo in Applications", error: model.moveError) {
                                Button("Move to Applications") { move() }
                            }
                        }
                        // Consiglio, non requisito (spec senza-aerospace §4): senza, la barra mostra le app aperte.
                        row("rectangle.3.group", "AeroSpace window manager",
                            description: "With AeroSpace the bar shows your workspaces; without it, the open apps.",
                            done: model.aerospace == .running) {
                            if model.aerospace == .installedNotRunning {
                                // AeroSpace ci mette un momento ad apparire tra le app in esecuzione: un refresh
                                // immediato lo trova ancora spento e la riga non diventa verde da sola.
                                Button("Open AeroSpace") {
                                    open("-b", aerospaceBundle)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.refresh() }
                                }
                            } else {
                                Button(homebrewPath == nil ? "Download…" : "Install with Homebrew") { installAerospaceInTerminal() }
                            }
                        }
                    case 1:
                        if settings.isOn(.status) {   // il Wi‑Fi sta nello Stato
                            row("wifi", "Location for Wi-Fi name", done: !model.noLocation) {
                                Button("Allow…") { requestLocation(); model.refresh() }
                            }
                        }
                    default:
                        let agents = integrations.compactMap { i in model.hooks[i.id].flatMap { $0.isMissing ? nil : (i, $0) } }
                        if agents.isEmpty { Text("No AI agents found.").foregroundStyle(.secondary) }
                        ForEach(agents, id: \.0.id) { i, status in
                            IntegrationRow(integration: i, status: status, refresh: model.refresh)
                        }
                    }
                } header: {
                    Text(stepTitle).font(.headline).textCase(nil)
                } footer: {
                    if model.step == 0 {
                        Text("dockduo starts at login. Change it in Settings.")
                    } else if model.step > 1 {
                        Text("Siigil uses the same Codex hooks file: after installing or removing these, Codex may ask to approve them again (/hooks → Trust).")
                    }
                }
            }
            .formStyle(.grouped)
            .animation(.smooth(duration: 0.2), value: model.step)
            HStack {
                Spacer()
                // I permessi sono solo quelli dello Stato: spento, il passo non ha niente da chiedere e si salta.
                let skip = settings.isOn(.status) ? 0 : 1
                Button("Back") { model.step -= model.step == 2 ? 1 + skip : 1 }.disabled(model.step == 0)
                if model.step < 2 {
                    Button("Next") { model.step += model.step == 0 ? 1 + skip : 1 }
                } else {
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        // Quasi nero (autore, 4/10): la finestra è sempre scura. I contenitori restano quelli di sistema: un fondo nostro
        // sotto le righe è stato provato e bocciato (autore, 4/10).
        .scrollContentBackground(.hidden)
        .background(Color(white: 0.07).ignoresSafeArea())
    }

    private var stepTitle: LocalizedStringKey {
        switch model.step {
        case 0: return "Basic setup"
        case 1: return "Permissions"
        default: return "AI agents"
        }
    }

    // Una riga: `done` mette il segno verde al posto di `trailing`; `error` in rosso sotto.
    @ViewBuilder private func row<Trailing: View>(_ symbol: String, _ title: LocalizedStringKey,
                                                    description: LocalizedStringKey? = nil,
                                                    done: Bool = false, error: String? = nil,
                                                    @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let description { Text(description).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3) } else { trailing() }
        }
        if let error { Text(error).font(.callout).foregroundStyle(.red) }
    }

    private func move() {
        do { try moveToApplications(); model.moveError = nil } catch { model.moveError = error.localizedDescription }
        model.refresh()
    }
}

// La riga di un agente: il simbolo, il nome e a destra il segno verde da collegato, o il pulsante che lo collega; sotto, in
// rosso, l'errore dell'ultima azione; per Codex con `.needsApproval` i due pulsanti dell'approvazione. Dopo ogni azione
// chiama `refresh`: il Benvenuto rilegge. Dal DMG niente Installa né Aggiorna: gli hook punterebbero dentro il disco immagine.
private struct IntegrationRow: View {
    let integration: Integration
    let status: IntegrationStatus
    let refresh: () -> Void
    @State private var error: String?
    @State private var restartPending = false   // "Open Terminal" premuto: il riavvio serve anche dopo l'approvazione

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").frame(width: 20).foregroundStyle(.secondary)
            Text(integration.name)
            Spacer()
            switch status {
            case .installed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            case .outdated, .notInstalled:
                if launchedFromDiskImage(Bundle.main.bundlePath) {
                    Text("Move dockduo to Applications first").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button(status == .outdated ? "Update" : "Install") { run(integration.install) }
                }
            case .needsApproval, .missing: EmptyView()   // l'approvazione ha i pulsanti sotto; chi manca non è nell'elenco
            }
        }
        if let error { Text(error).font(.callout).foregroundStyle(.red) }
        if integration.id == "codex", status == .needsApproval || restartPending {
            HStack {
                Button("Open Terminal") { openCodexTerminal(); restartPending = true }
                Button("Restart ChatGPT") { restartChatGPT(); restartPending = false }
            }
            .controlSize(.small)
        }
    }

    private func run(_ action: @escaping () throws -> Void) {
        integration.run(action) { error = $0; refresh() }
    }
}
