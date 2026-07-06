; Ruby4Lich5 — baked installer (non-DevKit, binary-gem factory model)
;
; The Ruby tree is built on the CI runner: stock RubyInstaller (.7z) extracted,
; then the precompiled binary gems are `gem install --local`'d straight into it.
; No MSYS2, no compilation, no prune — the binary gems are self-contained
; (they vendor their own DLLs). This installer just lays that finished tree down:
; one app, file-copy fast, responsive. DevKit stays optional via ridk.
;
; Build-time injected defines (workflow passes via ISCC /D...):
;   RubyVersion       e.g. 4.0.5 (resolved "latest 4.0.x")
;   LichVersion        the Lich release actually bundled -- read from whichever lich-tag
;                      was fetched, not generated; see docs/DECISIONS.md Phase 1 §5.
;   GemBundleVersion   the Ruby4Lich5 gem-bundle release actually baked in (stopgap
;                      placeholder until Phase 2 §6's publish mechanism exists)
;   InstallerVersion   Ruby4Lich5's own installer-build identity -- independent of both
;                      of the above; installer versioning is owned by Ruby4Lich5, not by
;                      lich-5 (docs/DECISIONS.md Phase 1 §4)

#ifndef RubyVersion
  #define RubyVersion "4.0.5"
#endif
#ifndef LichVersion
  #define LichVersion "0.0.0"
#endif
#ifndef GemBundleVersion
  #define GemBundleVersion "0.0.0-dev"
#endif
#ifndef InstallerVersion
  #define InstallerVersion "0.0.0"
#endif

#define MyAppName "Ruby4Lich5"
#define MyAppPublisher "Elanthia-Online"
#define MyAppURL "https://github.com/elanthia-online/lich-5/"

[Setup]
; AppId identifies the Lich 5 application; do NOT change it (new GUID only at Lich 6).
AppId={{edd9ccd7-33cb-4577-a470-fe8fd087eb07}
AppName={#MyAppName}
AppVersion={#InstallerVersion}
AppVerName={#MyAppName} Ruby {#RubyVersion} (Gems {#GemBundleVersion}) & Lich {#LichVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
SetupLogging=yes
ChangesAssociations=yes
ChangesEnvironment=true
DefaultDirName=C:\Ruby4Lich5
DisableStartupPrompt=Yes
DisableProgramGroupPage=Yes
DisableWelcomePage=Yes
DisableReadyPage=Yes
UsePreviousAppDir=No
PrivilegesRequired=lowest
OutputBaseFilename=Ruby4Lich5
SetupIconFile=.\fly64.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

[Types]
Name: "full";      Description: "Both Lich and Ruby"
Name: "lichonly";  Description: "Lich Installation Only"
Name: "rubyonly";  Description: "Ruby Installation Only"

[Components]
Name: "lich";     Description: "Lich Files";                             Types: full lichonly
Name: "rubygem";  Description: "Ruby {#RubyVersion} (64-bit) with Gems"; Types: full rubyonly

[Tasks]
; One of these two must default checked: both are "unchecked exclusive" radio-style
; tasks, but Inno Setup's "exclusive" flag only enforces *at most* one selected, not
; *exactly* one -- leaving both unchecked let a Full/Lich install complete without ever
; placing a usable Lich folder anywhere (files stayed only in the hidden R4LInstall
; staging directory). Desktop/Gemstone IV as the default is the more common case.
Name: LichGS;  Description: "Place in Desktop ({userdesktop}\Lich5 - preferred for Gemstone IV)";  GroupDescription: "Lich5 Folder Location";  Components: lich;    Flags: exclusive
Name: LichDR;  Description: "Place in Ruby4Lich5 ({app}\Lich5 - preferred for DragonRealms)";      GroupDescription: "Lich5 Folder Location";  Components: lich;    Flags: unchecked exclusive

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Dirs]
Name: "{app}\R4LInstall"; Attribs: hidden

[Files]
; The pre-baked Ruby tree: RubyInstaller + binary gems already installed in, staged by CI at .\ruby.
Source: ".\ruby\*";    DestDir: "{app}\{#RubyVersion}";                 Components: rubygem; Flags: ignoreversion createallsubdirs recursesubdirs
Source: ".\fly64.ico"; DestDir: "{app}\R4LInstall";                     Components: lich;    Flags: ignoreversion
Source: ".\Lich5\*";   DestDir: "{app}\R4LInstall\Lich{#LichVersion}";  Components: lich;    Flags: ignoreversion createallsubdirs recursesubdirs

[Registry]
; We lay down a tree (no RubyInstaller run), so we set associations + PATH ourselves.
; Restored verbatim from the legacy R4LGTK3.iss — proven for months.
Root: HKCU; Subkey: "SOFTWARE\Classes\.rb";                          ValueType: string; ValueName: ""; ValueData: "RubyFile";                                         Components: rubygem; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKCU; Subkey: "SOFTWARE\Classes\.rbw";                         ValueType: string; ValueName: ""; ValueData: "RubyWFile";                                        Components: rubygem; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKCU; Subkey: "SOFTWARE\Classes\RubyFile";                     ValueType: string; ValueName: ""; ValueData: "RubyFile";                                         Components: rubygem; Flags: uninsdeletekey
Root: HKCU; Subkey: "SOFTWARE\Classes\RubyWFile";                    ValueType: string; ValueName: ""; ValueData: "RubyWFile";                                        Components: rubygem; Flags: uninsdeletekey
Root: HKCU; Subkey: "SOFTWARE\Classes\RubyFile\DefaultIcon";         ValueType: string; ValueName: ""; ValueData: "{app}\{#RubyVersion}\bin\ruby.exe,0";              Components: rubygem; Flags: uninsdeletekey
Root: HKCU; Subkey: "SOFTWARE\Classes\RubyWFile\DefaultIcon";        ValueType: string; ValueName: ""; ValueData: "{app}\{#RubyVersion}\bin\rubyw.exe,0";             Components: rubygem; Flags: uninsdeletekey
Root: HKCU; Subkey: "SOFTWARE\Classes\RubyFile\shell\open\command";  ValueType: string; ValueName: ""; ValueData: """{app}\{#RubyVersion}\bin\ruby.exe"" ""%1"" %*";  Components: rubygem; Flags: uninsdeletekey
Root: HKCU; Subkey: "SOFTWARE\Classes\RubyWFile\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#RubyVersion}\bin\rubyw.exe"" ""%1"" %*"; Components: rubygem; Flags: uninsdeletekey
; Put Ruby bin, then the old PATH. Components: rubygem matters here specifically --
; without it, a "Lich Installation Only" install (no Ruby component at all) would still
; prepend a Ruby bin directory that was never actually installed.
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{app}\{#RubyVersion}\bin;{olddata}"; Components: rubygem; Flags: preservestringtype

[Run]
; Optional DevKit for developers — ridk ships in the baked tree; pulls ~1.5GB of
; MSYS2 over the network. Offered as a finish-page checkbox (postinstall), not a
; Tasks-page one: running this hidden mid-wizard (the old waituntilterminated
; runhidden combination) blocked the wizard's UI thread for the whole download,
; making Setup look hung. nowait + a visible console instead matches
; RubyInstaller's own reference .iss for this exact step.
Filename: "{app}\{#RubyVersion}\bin\ridk.cmd"; Parameters: "install 2 3"; \
  Description: "Install Ruby DevKit (developers — downloads MSYS2, needs network)"; \
  Components: rubygem; Flags: postinstall nowait skipifsilent unchecked

; Place Lich where the user chose (unchanged from the legacy installer).
Filename: "{cmd}"; Parameters: "/c""xcopy /i /e /s /y ""{app}\R4LInstall\Lich{#LichVersion}"" ""{userdesktop}\Lich5"""""; Tasks: LichGS
Filename: "{cmd}"; Parameters: "/c""xcopy /i /e /s /y ""{app}\R4LInstall\Lich{#LichVersion}"" ""{app}\Lich5""""";         Tasks: LichDR
