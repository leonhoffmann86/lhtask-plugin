# LHTask — Architektur & Funktionsweise

> Visualisierung der `lhtask`-Plugin-Mechanik in voller Tiefe. Alle Diagramme sind
> [Mermaid](https://mermaid.js.org/) und rendern direkt auf GitHub — keine externen Bilder.

Inhalt:

1. [Zwei Welten: Plugin-Repo vs. Ziel-Repo](#1-zwei-welten-plugin-repo-vs-ziel-repo)
2. [System-Überblick](#2-system-überblick)
3. [Der Lebenszyklus einer Idee](#3-der-lebenszyklus-einer-idee)
4. [Das `post-commit`-Routing](#4-das-post-commit-routing)
5. [Die Kette als Sequenz (Plan → Implement → Review)](#5-die-kette-als-sequenz)
6. [Worktree-Isolation der Implement-Stage](#6-worktree-isolation-der-implement-stage)
7. [Datei-Lebenszyklus & die Skip-Konvention](#7-datei-lebenszyklus--die-skip-konvention)
8. [Schleifen-Sicherheit (warum es nicht rekursiv explodiert)](#8-schleifen-sicherheit)
9. [Locking & Detached-Ausführung](#9-locking--detached-ausführung)
10. [Bootstrap: wie die Kette in ein Repo kommt](#10-bootstrap)
11. [Konfiguration als einzige Wahrheitsquelle](#11-konfiguration)

---

## 1. Zwei Welten: Plugin-Repo vs. Ziel-Repo

Das Wichtigste zuerst — der mentale Bruch, ohne den nichts Sinn ergibt:
**Die Skripte in `templates/` laufen hier nie.** Es sind parametrisierte Vorlagen, die
`bootstrap` per `cp -n` in ein *anderes* Repo kopiert. Erst dort laufen sie als git-Hook.

```mermaid
flowchart LR
    subgraph PLUGIN["🧩 Plugin-Repo (dieses Repo) — Quelle der Wahrheit"]
        direction TB
        SK1["skills/lh-task/SKILL.md<br/>Idee → 1 TODO-Item"]
        SK2["skills/bootstrap/SKILL.md<br/>idempotenter Installer"]
        TPL["templates/<br/>githooks/ · scripts/ · lhtask.conf<br/>AGENTS.md · TODO/DONE/AGENT_LOG"]
    end

    subgraph TARGET["📦 Ziel-Repo (irgendein Projekt) — hier läuft alles"]
        direction TB
        HOOK[".githooks/post-commit"]
        SCR["scripts/lhtask-*.sh"]
        CONF["lhtask.conf<br/>(angepasst an Projekt)"]
        LIFE["TODO.md · DONE.md · AGENT_LOG.md<br/>AGENTS.md (Verfassung)"]
    end

    SK2 -- "cp -n  (einmalig, /lhtask:bootstrap)" --> HOOK
    SK2 -- "cp -n" --> SCR
    SK2 -- "cp -n + autodetect" --> CONF
    SK2 -- "cp -n (nur falls fehlend)" --> LIFE
    SK1 -. "schreibt (im Ziel-Repo)" .-> LIFE

    style PLUGIN fill:#eef2ff,stroke:#6366f1
    style TARGET fill:#f0fdf4,stroke:#16a34a
```

> Konsequenz: Ein Skript hier zu ändern, beeinflusst **jedes künftig gebootstrappte Repo** —
> aber **nicht** die git-Aktivität dieses Repos selbst.

---

## 2. System-Überblick

Zwei Einstiegspunkte (Skills, vom Menschen aufgerufen) und eine dreistufige Kette
(Hooks, vom Commit ausgelöst).

```mermaid
flowchart TB
    HUMAN(["👤 Mensch"])

    subgraph SKILLS["Skills — interaktiv, schreiben keinen Code"]
        LHTASK["/lhtask:lh-task '&lt;Idee&gt;'<br/><i>Refinement: Idee → 1 strukturiertes TODO-Item</i>"]
        BOOT["/lhtask:bootstrap<br/><i>Installer: Hooks + Config + Starter</i>"]
    end

    COMMIT[["git commit"]]

    subgraph CHAIN["Die autonome Kette — headless claude, via post-commit"]
        direction TB
        PLAN["① PLAN<br/>lhtask-plan.sh<br/>→ TODO.autoplan.md"]
        IMPL["② IMPLEMENT<br/>lhtask-implement.sh<br/>isolierter worktree, 1 Commit/Item"]
        REV["③ REVIEW<br/>lhtask-review.sh<br/>→ TODO.review.md (nur Report)"]
    end

    HUMAN --> LHTASK
    HUMAN --> BOOT
    BOOT -. "richtet ein" .-> CHAIN
    LHTASK -- "füllt TODO.md" --> COMMIT
    HUMAN -- "committet TODO.md" --> COMMIT
    COMMIT --> PLAN
    PLAN -- "chained im selben Lauf" --> IMPL
    IMPL -- "reviewt eigene Commits" --> REV
    COMMIT -- "Änderung in Review-Dirs" --> REV

    REV -. "Report + ❌-Loopback" .-> HUMAN
    IMPL -. "Branch autoplan/impl<br/>(nie auto-gemerged)" .-> HUMAN

    style SKILLS fill:#eef2ff,stroke:#6366f1
    style CHAIN fill:#fff7ed,stroke:#ea580c
```

---

## 3. Der Lebenszyklus einer Idee

Von der vagen Notiz bis zum reviewten Branch — der „Happy Path“ aus Nutzersicht.

```mermaid
flowchart LR
    A["💡 vage Idee"] --> B["/lhtask:lh-task"]
    B --> C{"Frage oder<br/>Aufgabe?"}
    C -- "Frage" --> C1["aus Code beantworten"]
    C -- "Aufgabe" --> D["am echten Code erden<br/>(codegraph / Grep)"]
    D --> E["Risiko-Tier + Scope<br/>+ Done-Kriterium klären"]
    E --> F["1 strukturiertes Item<br/>in TODO.md"]
    F --> G[["git commit TODO.md"]]
    G --> H["① PLAN → TODO.autoplan.md"]
    H --> I["② IMPLEMENT<br/>(worktree, autoplan/impl)"]
    I --> J{"Risiko?"}
    J -- "hoch" --> K["🚧 Deferred<br/>(Mensch entscheidet)"]
    J -- "low/med" --> L{"Test grün?"}
    L -- "✅" --> M["1 Commit:<br/>Code + TODO→DONE + LOG"]
    L -- "❌" --> N["Code verwerfen<br/>→ 🚧 Deferred + Grund"]
    M --> O["③ REVIEW des Branches<br/>→ TODO.review.md"]
    O --> P{"Mensch:<br/>mergen?"}
    P -- "ja" --> Q["merge autoplan/impl"]
    P -- "nein" --> R["verwerfen"]

    style K fill:#fef2f2,stroke:#dc2626
    style M fill:#f0fdf4,stroke:#16a34a
    style Q fill:#f0fdf4,stroke:#16a34a
```

---

## 4. Das `post-commit`-Routing

Der Hook ist der Dispatcher. Er entscheidet anhand der **geänderten Dateien** im Commit,
welche Stage(s) laufen — und steigt bei Agent-Commits / Killswitch sofort aus.

```mermaid
flowchart TB
    START(["post-commit feuert"]) --> G1{"AUTOPLAN_AGENT=1?"}
    G1 -- "ja" --> X(["exit 0 — Agent-Commit, kein Re-Trigger"])
    G1 -- "nein" --> G2{".git/autoplan.disabled?"}
    G2 -- "ja" --> X2(["exit 0 — Killswitch"])
    G2 -- "nein" --> G3{"HEAD~1 existiert?"}
    G3 -- "nein" --> X3(["exit 0 — erster Commit"])
    G3 -- "ja" --> SYNC["codegraph sync (falls vorhanden)<br/>— hält Index frisch, scheitert nie"]
    SYNC --> DIFF["changed = git diff --name-only HEAD~1 HEAD"]

    DIFF --> C1{"TODO.md<br/>geändert?"}
    C1 -- "ja" --> PLAN["scripts/lhtask-plan.sh<br/>(→ chained implement)"]
    C1 -- "nein" --> C2

    PLAN --> C2{"Datei in<br/>LHTASK_REVIEW_DIRS/<br/>geändert?"}
    C2 -- "ja" --> REV["scripts/lhtask-review.sh"]
    C2 -- "nein" --> END(["exit 0"])
    REV --> END

    style X fill:#f3f4f6,stroke:#9ca3af
    style X2 fill:#fef2f2,stroke:#dc2626
    style X3 fill:#f3f4f6,stroke:#9ca3af
```

> Das Review-Regex wird dynamisch aus der Config gebaut:
> `review_re="^(${LHTASK_REVIEW_DIRS// /|})/"` → aus `"src tests"` wird `^(src|tests)/`.

---

## 5. Die Kette als Sequenz

Der vollständige Ablauf eines `TODO.md`-Commits über alle Akteure hinweg — inklusive
der Selbst-Review der autonomen Arbeit.

```mermaid
sequenceDiagram
    autonumber
    actor U as 👤 Mensch
    participant H as post-commit
    participant P as lhtask-plan.sh
    participant I as lhtask-implement.sh
    participant W as git worktree<br/>(autoplan/impl)
    participant C as headless claude
    participant R as lhtask-review.sh

    U->>H: commit TODO.md
    H->>H: Guards (AGENT? disabled? HEAD~1?)
    H->>P: TODO.md geändert → starte Plan

    activate P
    P->>P: Lock nehmen · TODO.run.log resetten
    P->>P: lhtask_strip_skipped(TODO.md) → ACTIVE
    P->>C: Plan-Prompt (Verfassung + ACTIVE)
    C-->>P: TODO.autoplan.md (Sub-Steps + Risiko)
    P->>I: chain implement (selber detached Lauf)
    deactivate P

    activate I
    I->>W: git worktree add -B autoplan/impl HEAD
    Note over I,W: venv + codegraph.db symlinken
    I->>C: Implement-Prompt (ACTIVE + PLAN + DONE)
    activate C
    loop pro aktivem Item
        C->>C: Risiko klassifizieren
        alt high-risk
            C->>W: Item → 🚧 Deferred (nicht implementiert)
        else low/medium
            C->>W: Test (LHTASK_TEST_CMD)
            alt grün
                C->>W: 1 Commit: Code + TODO→DONE + AGENT_LOG
            else rot
                C->>W: Code verwerfen → 🚧 Deferred + Grund
            end
        end
    end
    Note right of C: alle Commits mit<br/>AUTOPLAN_AGENT=1
    deactivate C
    I->>I: IMPL_SHA merken, worktree entfernen<br/>(Branch bleibt!)
    I->>R: Review des Branches (LHTASK_REVIEW_AUTONOMOUS=1)
    deactivate I

    activate R
    R->>C: Review-Prompt (git log HEAD..autoplan/impl)
    C-->>R: TODO.review.md (✅/⚠️/❌ je Aspekt)
    R->>R: surface: Ampel + ❌→🔎 in TODO.md + AGENT_LOG
    deactivate R
    R-->>U: "✅ x ⚠️ y ❌ z — siehe TODO.review.md"
    U->>U: git log autoplan/impl → mergen oder verwerfen
```

---

## 6. Worktree-Isolation der Implement-Stage

Warum die Implement-Stage **nie** den Arbeitsbaum berührt: Sie arbeitet in einem
wegwerfbaren `git worktree` auf einem eigenen Branch.

```mermaid
flowchart TB
    subgraph MAIN["Haupt-Repo (dein Arbeitsbaum, unangetastet)"]
        WT_MAIN["working tree<br/>branch: main"]
        DB[".codegraph/codegraph.db"]
        VENV[".venv"]
    end

    subgraph WORKTREE[".git/lhtask-worktree — wegwerfbar"]
        direction TB
        WT_IMPL["isolierter Checkout<br/>branch: autoplan/impl"]
        LN1["↳ .venv (symlink)"]
        LN2["↳ .codegraph/codegraph.db (symlink)"]
    end

    WT_MAIN -- "git worktree add -f -B autoplan/impl HEAD" --> WT_IMPL
    VENV -. "ln -s (nur falls LHTASK_VENV gesetzt)" .-> LN1
    DB -. "ln -s (Caller/Impact-Analyse)" .-> LN2

    WT_IMPL --> COMMITS["1 Commit pro Item<br/>(AUTOPLAN_AGENT=1)"]
    COMMITS --> KEEP["Branch bleibt im Repo bestehen"]
    COMMITS --> DROP["worktree remove --force<br/>(Verzeichnis weg, Commits bleiben)"]
    KEEP --> HUMAN["👤 git log autoplan/impl<br/>→ merge oder discard"]

    style MAIN fill:#f0fdf4,stroke:#16a34a
    style WORKTREE fill:#fff7ed,stroke:#ea580c
    style HUMAN fill:#eef2ff,stroke:#6366f1
```

> **Vor** dem Anlegen wird hart aufgeräumt (`worktree remove --force` → `rm -rf` →
> `worktree prune`), damit eine verwaiste Registrierung eines abgebrochenen Laufs den
> neuen `worktree add` nicht blockiert.

---

## 7. Datei-Lebenszyklus & die Skip-Konvention

Welche Datei was bedeutet — und wie der Mensch mit drei Markierungen steuert, was die
Kette anfasst. `lhtask_strip_skipped` filtert vor jeder Plan-/Implement-Stage.

```mermaid
flowchart LR
    subgraph TRACKED["versioniert (vom Menschen besessen)"]
        TODO["TODO.md<br/>offene Arbeit"]
        DONE["DONE.md<br/>erledigt (+ Datum + Branch-Ref)<br/>= Idempotenz-Anker"]
        LOG["AGENT_LOG.md<br/>chronologische Historie"]
        CONST["AGENTS.md<br/>Verfassung / Risiko-Tiers"]
    end

    subgraph SIDECARS["gitignored Sidecars (Agent-Output)"]
        AUTOPLAN["TODO.autoplan.md<br/>Plan-Vorschläge"]
        REVIEW["TODO.review.md<br/>Review-Report"]
        RUNLOG["TODO.run.log<br/>Live-Trace (tail -f)"]
    end

    TODO -- "Item erledigt" --> DONE
    PLAN_S["① Plan"] --> AUTOPLAN
    IMPL_S["② Implement"] --> DONE
    IMPL_S --> LOG
    REV_S["③ Review"] --> REVIEW
    REV_S -- "❌ gefunden" --> TODO

    style SIDECARS fill:#f9fafb,stroke:#9ca3af,stroke-dasharray: 5 5
    style TRACKED fill:#f0fdf4,stroke:#16a34a
```

**Die Skip-Konvention in `TODO.md`** — was Plan/Implement **ignorieren**:

```mermaid
flowchart TB
    FILE["TODO.md"] --> STRIP["lhtask_strip_skipped (awk)"]
    STRIP --> ACTIVE["✅ AKTIV — wird geplant & implementiert<br/>(normale - [ ] Items)"]
    STRIP --> SKIP1["🗨️ in &lt;!-- … --&gt; auskommentiert → übersprungen"]
    STRIP --> SKIP2["## 🚧 Deferred → übersprungen<br/>(high-risk / fehlgeschlagen)"]
    STRIP --> SKIP3["## 🔎 Review-Findings → übersprungen<br/>(menschlicher Hinweis, keine Aufgabe)"]

    style ACTIVE fill:#f0fdf4,stroke:#16a34a
    style SKIP1 fill:#f3f4f6,stroke:#9ca3af
    style SKIP2 fill:#fef2f2,stroke:#dc2626
    style SKIP3 fill:#fffbeb,stroke:#d97706
```

> Hebel für „nur dieses eine Item bearbeiten“: die anderen aktiven Items in einen
> `<!-- … -->`-Block oder unter `## 🚧 Deferred` verschieben.

---

## 8. Schleifen-Sicherheit

Die Kette committet selbst — und jeder Commit feuert wieder `post-commit`. Ohne Schutz
wäre das eine Endlosschleife. Der Schutz ist eine einzige Umgebungsvariable.

```mermaid
flowchart TB
    H1["Mensch committet TODO.md"] --> HOOK1["post-commit<br/>AUTOPLAN_AGENT? → nein"]
    HOOK1 --> RUN["Kette läuft<br/>(claude mit AUTOPLAN_AGENT=1)"]
    RUN --> AC["Agent committet auf autoplan/impl"]
    AC --> HOOK2["post-commit feuert erneut"]
    HOOK2 --> CHECK{"AUTOPLAN_AGENT=1?"}
    CHECK -- "JA" --> STOP(["exit 0 — kein Re-Trigger ✋"])
    CHECK -. "wäre nein → ∞" .-> LOOP(["💥 Endlosschleife"])

    style STOP fill:#f0fdf4,stroke:#16a34a
    style LOOP fill:#fef2f2,stroke:#dc2626,stroke-dasharray: 5 5
```

Zwei weitere Konsequenzen derselben Variable:

- Weil Agent-Commits den Hook überspringen, kann er die autonome Arbeit **nicht** selbst
  reviewen → deshalb ruft `lhtask-implement.sh` die Review-Stage am Ende **selbst** auf.
- Auch Plan- und Review-Stage setzen `AUTOPLAN_AGENT=1` defensiv, damit jede git-Aktivität
  von innen heraus nicht rekursiert.

---

## 9. Locking & Detached-Ausführung

Jede Stage ist nebenläufigkeits-sicher und blockiert den Commit nicht.

```mermaid
flowchart TB
    START["Stage startet"] --> REAP["lhtask_reap_stale_lock<br/>(Lock älter als N min → entfernen)"]
    REAP --> LOCK{"mkdir .git/lhtask-*.lock"}
    LOCK -- "scheitert (läuft schon)" --> SKIP(["exit 0 — sauber überspringen"])
    LOCK -- "ok" --> MODE{"LHTASK_FOREGROUND=1?"}
    MODE -- "nein (default)" --> BG["( do_run ) &amp; — detached<br/>Commit kehrt sofort zurück"]
    MODE -- "ja (debug)" --> FG["( do_run ) — synchron"]
    BG --> WORK["claude läuft (~Minuten)<br/>tee → TODO.run.log + .git/lhtask-*.log"]
    FG --> WORK
    WORK --> RELEASE["trap EXIT: rmdir lock"]

    style SKIP fill:#f3f4f6,stroke:#9ca3af
    style BG fill:#eef2ff,stroke:#6366f1
```

- `mkdir` als atomares Lock (ein Lauf gewinnt; Nebenläufer steigen sauber aus).
- `reap_stale_lock` verhindert, dass ein gekillter Lauf die Kette permanent blockiert.
- **Detached by default** → der Commit kehrt sofort zurück, ein Platzhalter landet sofort
  im Sidecar. `LHTASK_FOREGROUND=1` ist der Debug-/Test-Hebel (synchron).

---

## 10. Bootstrap

Wie die Kette einmalig in ein Repo eingebaut wird — idempotent, nichts wird stillschweigend überschrieben.

```mermaid
flowchart TB
    S0["/lhtask:bootstrap"] --> S1["Templates finden<br/>${CLAUDE_PLUGIN_ROOT}/templates"]
    S1 --> S2{"git-Repo?"}
    S2 -- "nein" --> OFFER["git init anbieten"]
    S2 -- "ja" --> S3["Projekttyp erkennen<br/>pyproject/package.json/go.mod/Cargo.toml"]
    S3 --> S4["Config-Defaults vorschlagen<br/>TEST_CMD · VENV · REVIEW_DIRS"]
    S4 --> S5["cp -n: Hooks + scripts/<br/>(clobbert nie)"]
    S5 --> S6["lhtask.conf schreiben<br/>(mit erkannten Werten)"]
    S6 --> S7["Lifecycle + AGENTS.md seeden<br/>(nur falls fehlend)"]
    S7 --> S8[".gitignore ergänzen<br/>autoplan/review/run.log"]
    S8 --> S9["git config core.hooksPath .githooks"]
    S9 --> S10[".claude/settings.json<br/>Allowlist mergen (keine abs. Pfade)"]
    S10 --> DONE(["✅ Repo ist plug-and-play"])

    style DONE fill:#f0fdf4,stroke:#16a34a
    style OFFER fill:#fffbeb,stroke:#d97706
```

---

## 11. Konfiguration

`lhtask.conf` ist die **einzige Wahrheitsquelle**. Achtung: die Defaults sind an drei
Stellen dupliziert, die synchron bleiben müssen.

```mermaid
flowchart LR
    CONF["lhtask.conf<br/>(Ziel-Repo)"]
    LIB["lhtask_load_config<br/>in lhtask-lib.sh"]
    HOOK["inline-Defaults<br/>in post-commit"]

    CONF -- "voll gesourct von allen Stages" --> LIB
    CONF -- "nur REVIEW_DIRS + CODEGRAPH<br/>vor dem lib-source" --> HOOK
    LIB -. "müssen synchron sein" .-> HOOK

    style CONF fill:#eef2ff,stroke:#6366f1
```

| Key | Bedeutung |
| --- | --- |
| `LHTASK_REVIEW_DIRS` | Dirs, deren Änderung die Review-Stage triggert (z. B. `src tests`) |
| `LHTASK_TEST_CMD` | Test, der grün sein muss; `{path}` → vom Agent gewähltes Ziel |
| `LHTASK_CONSTITUTION_FILES` | Dateien, die jede Stage zuerst liest (default `AGENTS.md`) |
| `LHTASK_IMPL_BRANCH` | Branch der Implement-Stage (default `autoplan/impl`) |
| `LHTASK_VENV` | venv, das in den worktree gesymlinkt wird (Python); leer für Node/Go |
| `LHTASK_CODEGRAPH` | `auto` \| `on` \| `off` |
| `LHTASK_MODEL` | Modell-Override für headless-Läufe (leer = default) |
| `LHTASK_REVIEW_AUTONOMOUS` | `1` = auch die impl-Branch-Commits reviewen |
| `LHTASK_NOTIFY` | `1` = Desktop-Notification bei Review-Ende |

---

### Debugging-Spickzettel

```bash
tail -f TODO.run.log                        # konsolidierter Live-Trace (pro Trigger resettet)
LHTASK_FOREGROUND=1 .githooks/post-commit   # getriggerte Stage synchron ausführen
cat .git/lhtask-implement.log               # roher Per-Stage-Log
touch .git/autoplan.disabled                # Killswitch (entfernen = wieder an)
```
