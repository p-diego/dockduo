APP = .build/dockduo.app
BIN = .build/release/Dockduo
INSTALLED = $(HOME)/Applications/dockduo.app
DMG = .build/dockduo-$(VERSION).dmg
STAGE = .build/dmg
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
# Firma: il certificato "Apple Development" del portachiavi se c'è (lo crea Xcode con l'Apple ID), altrimenti ad-hoc.
# Con il certificato macOS lega i permessi (la Posizione) al nome sul certificato: restano da
# una build all'altra e dopo il rinnovo annuale. Ad-hoc li lega all'hash della singola build: si azzerano a ogni
# installazione (verificato il 2026-09-22). Si usa l'impronta SHA-1 del primo certificato valido.
SIGN_ID = $(or $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $$2; exit}'),-)

.PHONY: build run cpu test install uninstall dist dmg release

build:
	swift build -c release
	rm -rf $(APP)   # da capo: un file tolto dalle risorse non deve restare nell'app (e nelle release)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/dockduo
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/dockduo-hook $(APP)/Contents/Resources/dockduo-hook
	# La licenza di dockduo: la cita Informazioni su dockduo.
	mkdir -p $(APP)/Contents/Resources/Licenses && cp LICENSE $(APP)/Contents/Resources/Licenses/dockduo.txt
	cp -R Resources/*.lproj $(APP)/Contents/Resources/
	# Icona (Icon Composer, Resources/icon/dockduo_icon.icon): actool produce Assets.car (glass, macOS 26+) e l'.icns
	# Percorsi assoluti: actool passa il lavoro a un servizio che resta aperto e risolve quelli relativi dalla cartella della
	# sua prima chiamata, non da quella di make (visto il 27/9: "output directory does not exist" in un'altra cartella).
	xcrun actool $(CURDIR)/Resources/icon/dockduo_icon.icon --compile $(CURDIR)/$(APP)/Contents/Resources --platform macosx \
		--minimum-deployment-target 26.0 --app-icon dockduo_icon --output-partial-info-plist /dev/null >/dev/null
	# Firma dell'intero bundle con identificatore stabile (SIGN_ID: certificato Apple Development o ad-hoc). Nessun
	# timestamp: la build non è notarizzata e così non serve la rete.
	codesign --force --deep --timestamp=none --sign $(SIGN_ID) --identifier com.dockduo.app $(APP)

# Esce con garbo (applicationWillTerminate ripristina le linee ai lati di AeroSpace); pkill solo se dopo ~3 s è ancora viva.
QUIT = osascript -e 'quit app id "com.dockduo.app"' 2>/dev/null; n=0; while pgrep -x dockduo >/dev/null; do sleep 0.1; n=$$((n+1)); [ $$n -gt 30 ] && pkill -x dockduo; done; true

# Chiude la vecchia istanza e aspetta che sia uscita prima di chiamare open
# (altrimenti LaunchServices "riapre" la vecchia). Non tocca SketchyBar né AeroSpace.
run: build
	$(QUIT)
	open $(APP)

# Misura la differenza di tempo CPU in 16 s (spec prestazioni §2): rilancia la build di sviluppo, aspetta che si assesti.
# ps %cpu è una media decadente che include l'avvio. Misura anche il WindowServer: è lì che finisce il costo del vetro
# (ogni ridisegno della barra lo paga il compositore, non dockduo). Serve prima/dopo ogni modifica al ridisegno.
cpu: run
	@sleep 8; pid=$$(pgrep -x dockduo) || { echo "dockduo non è partita"; exit 1; }; ws=$$(pgrep -x WindowServer); \
	t0=$$(ps -o cputime= -p $$pid); w0=$$(ps -o cputime= -p $$ws); sleep 16; t1=$$(ps -o cputime= -p $$pid); w1=$$(ps -o cputime= -p $$ws); \
	echo "$$t0 $$t1 $$w0 $$w1" | awk '{ split($$1, a, ":"); split($$2, b, ":"); split($$3, c, ":"); split($$4, d, ":"); \
	  printf "CPU media: dockduo %.1f%%, WindowServer %.1f%%\n", ((b[1]*60+b[2]) - (a[1]*60+a[2])) / 16 * 100, ((d[1]*60+d[2]) - (c[1]*60+c[2])) / 16 * 100 }'

# I test del pacchetto (swift test); `release` li lancia prima di taggare.
test:
	swift test

# Copia in ~/Applications e lancia; l'app si registra da sola come elemento di login (SMAppService, main.swift).
install: build
	$(QUIT)
	mkdir -p $(HOME)/Applications
	rm -rf $(INSTALLED) && cp -R $(APP) $(INSTALLED)
	open $(INSTALLED)

uninstall:
	$(QUIT); rm -rf $(INSTALLED); true

# Zip da distribuire a mano (firma ad-hoc: chi lo installa toglie la quarantena, vedi DEVELOPMENT.md).
dist: build
	ditto -c -k --keepParent $(APP) .build/dockduo-$(VERSION).zip
	@echo .build/dockduo-$(VERSION).zip

# Immagine disco per le persone: l'app e il collegamento ad Applicazioni in una finestra con sfondo quasi nero, freccia e
# nota sul primo avvio (Resources/dmg/background.swift la disegna a ogni build; layout.applescript la fa impaginare al
# Finder, che la prima volta chiede il permesso Automazione a chi lancia make). HFS+ in lettura-scrittura per impostare la
# finestra, poi convertita compressa. Lo zip resta per gli script (dotfiles) e per l'aggiornamento da dentro l'app.
# Un /Volumes/dockduo già montato (un DMG di prima) farebbe montare questo come "dockduo 1": SetFile, l'impaginazione e
# l'espulsione lavorerebbero sull'altro.
dmg: build
	[ ! -e /Volumes/dockduo ] || { echo "Espelli /Volumes/dockduo prima"; exit 1; }
	rm -rf $(STAGE) $(DMG) .build/dockduo-rw.dmg
	mkdir -p $(STAGE)/.background
	cp -R $(APP) $(STAGE)/
	ln -s /Applications $(STAGE)/Applications
	swift Resources/dmg/background.swift $(STAGE)/.background/background.png
	cp $(APP)/Contents/Resources/dockduo_icon.icns $(STAGE)/.VolumeIcon.icns
	hdiutil create -volname dockduo -srcfolder $(STAGE) -fs HFS+ -format UDRW -ov -quiet .build/dockduo-rw.dmg
	hdiutil attach -readwrite -noverify -noautoopen -quiet .build/dockduo-rw.dmg
	command -v SetFile >/dev/null && SetFile -a C /Volumes/dockduo || true
	osascript Resources/dmg/layout.applescript
	hdiutil detach -quiet /Volumes/dockduo
	hdiutil convert -format UDZO -o $(DMG) -quiet .build/dockduo-rw.dmg
	rm -f .build/dockduo-rw.dmg
	@echo $(DMG)

# Pubblica lo zip e il DMG come GitHub Release v<versione> (da Info.plist): servono i test verdi, l'albero pulito
# e una versione nuova. Il tag punta al commit locale, non alla testa del remote.
release: test dist dmg
	# Una release ad-hoc (nessun certificato Apple Development valido) non la installerebbe nessuno: nessuna copia si aggiornerebbe da sola.
	[ "$(SIGN_ID)" != "-" ] || { echo "Nessun certificato Apple Development valido: una release ad-hoc non si aggiornerebbe"; exit 1; }
	# Anche i file nuovi: lo zip si fa dall'albero, il tag dal commit, e un file mai aggiunto finirebbe solo nel primo (review 4/10).
	[ -z "$$(git status --porcelain)" ] || { echo "Modifiche o file nuovi non committati: fai commit prima"; exit 1; }
	git tag v$(VERSION)
	git push origin v$(VERSION)
	# Solo su p-diego/dockduo: da lì si aggiornano le app installate. Le note sono l'oggetto del commit.
	gh release create --repo p-diego/dockduo v$(VERSION) .build/dockduo-$(VERSION).zip $(DMG) --verify-tag --notes "$$(git log -1 --format=%s)"
