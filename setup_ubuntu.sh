#!/usr/bin/env bash
#
# ============================================================================
#  OpenMontage — bootstrap complet d'un poste Ubuntu neuf
# ============================================================================
#  Reconstruit, de zéro, l'environnement de travail : dépendances système,
#  opencode, le repo OpenMontage (git init + fetch SSH + venv + make
#  setup/install-dev), et la liaison GitHub par clé SSH (Deploy key).
#
#  PAS DE CLONE INITIAL REQUIS : télécharge ce script puis lance-le.
#  Le repo est privé → le script passe par SSH (clé à ajouter sur GitHub).
#
#    curl -fsSL https://raw.githubusercontent.com/yakuzas2345/openmontage_base/main/setup_ubuntu.sh -o setup_ubuntu.sh
#    bash setup_ubuntu.sh                           # .env créé depuis .env.example
#    bash setup_ubuntu.sh /chemin/.env              # .env copié depuis une machine existante
#
#  Avant chaque téléchargement, le script vérifie que la dépendance manque
#  vraiment, puis demande l'autorisation de l'installer.
#
#  Variables d'environnement (optionnel):
#    OPENMONTAGE_DIR=/path/to/OpenMontage           # dossier du repo (défaut ~/OpenMontage)
#    NODE_MAJOR=22                                  # version Node installée via nvm
#    BOOTSTRAP_BRANCH=mon-setup                     # nom de la branche de setup (défaut: setup-<user>_story)
#    ASSUME_YES=1                                   # répond Oui aux invites
# ============================================================================

set -euo pipefail

GITHUB_REPO="yakuzas2345/openmontage_setup.git"
GITHUB_STORY_REPO="yakuzas2345/openmontage_story.git"
GITHUB_HOST_ALIAS="openmontage_setup"          # identité "repo" : fetch + push du setup vers main (openmontage_setup)
GITHUB_MAIN_ALIAS="openmontage_story"     # identité "main" : push des storyboards (openmontage_story)
SSH_KEY="${HOME}/.ssh/id_ed25519_openmontage_setup"           # clé repo : openmontage_setup (projet / setup)
SSH_KEY_MAIN="${HOME}/.ssh/id_ed25519_openmontage_story" # clé main : openmontage_story (storyboards)
OPENMONTAGE_DIR="${OPENMONTAGE_DIR:-${HOME}/OpenMontage}"
NODE_MAJOR="${NODE_MAJOR:-22}"
SRC_ENV="${1:-}"
# Branche locale créée par le setup (jamais 'main') — surchargeable.
BOOTSTRAP_BRANCH="${BOOTSTRAP_BRANCH:-setup-$(whoami 2>/dev/null || echo user)_story}"

section() { echo; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo "▶ $1"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
log()     { echo "  · $1"; }

# Demande une confirmation (O/n). Retour 0 si oui, 1 si non.
# ASSUME_YES=1 (ou true/yes) répond toujours Oui.
confirm() {
  local msg="$1"
  case "${ASSUME_YES:-0}" in
    1|true|yes|oui) echo "  · $msg → oui (ASSUME_YES)"; return 0 ;;
  esac
  while true; do
    read -r -p "  ${msg} [O/n] " ans
    case "${ans:-O}" in
      O|o|oui|Oui|y|Y|yes|Yes) return 0 ;;
      n|N|non|Non|no|No)        return 1 ;;
      *) echo "  Réponds O (oui) ou n (non)." ;;
    esac
  done
}

require_root_or_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    sudo() { "$@"; }
  elif ! command -v sudo >/dev/null 2>&1; then
    echo "ERREUR: sudo est requis (ou exécutez en root)." >&2; exit 1
  fi
}

# Ensure current user has a password set so sudo NOPASSWD works
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  if ! getent passwd "$(whoami)" | grep -qE '!:|\\*'; then
    echo "$(whoami):password" | chpasswd 2>/dev/null || true
  fi
fi

# ────────────────────────────────────────────────────────────────────────
#  Vérification des dépendances système (apt) — ne télécharge rien.
#  Remplit APT_NEEDED avec les paquets manquants.
# ────────────────────────────────────────────────────────────────────────
measure_apt_deps() {
  declare -A pkgs=()
  want() { pkgs["$2"]=1; }
  command -v git     >/dev/null 2>&1 || want git git
  command -v curl    >/dev/null 2>&1 || want curl curl
  command -v make    >/dev/null 2>&1 || want make build-essential
  command -v gcc     >/dev/null 2>&1 || want gcc build-essential
  command -v ffmpeg  >/dev/null 2>&1 || want ffmpeg ffmpeg
  command -v ffprobe >/dev/null 2>&1 || want ffprobe ffmpeg
  command -v python3 >/dev/null 2>&1 || want python3 python3
  command -v pip3    >/dev/null 2>&1 || want pip3 python3-pip
  if ! python3 -c "import venv" >/dev/null 2>&1; then want venv python3-venv; fi
  APT_NEEDED="${!pkgs[*]}"
}

# ────────────────────────────────────────────────────────────────────────
#  Vérification générale : liste les binaires manquants (code 1 si absent).
# ────────────────────────────────────────────────────────────────────────
report_runtime_gaps() {
  local b
  GAPS=""
  for b in git curl make gcc ffmpeg ffprobe python3 pip3 node npm npx opencode; do
    command -v "$b" >/dev/null 2>&1 || GAPS="${GAPS} $b"
  done
  if [ -z "${GAPS}" ]; then return 0; else return 1; fi
}

# ────────────────────────────────────────────────────────────────────────
section "1/8 — Détection OS"
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  log "Distribution: ${ID} ${VERSION_ID} (${PRETTY_NAME})"
else
  echo
  echo "⛔ Impossible d'identifier la distribution : /etc/os-release introuvable." >&2
  echo "   Ce script ne fonctionne que sur Ubuntu ou Debian. Arrêt." >&2
  exit 1
fi
if [ "${ID}" != "ubuntu" ] && [ "${ID}" != "debian" ]; then
  echo
  echo "⛔ Distribution non supportée : '${ID}' (${PRETTY_NAME})." >&2
  echo "   Ce script ne fonctionne que sur Ubuntu ou Debian." >&2
  echo "   Arrêt avant toute modification du système." >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
  echo
  echo "⛔ Ubuntu détecté, mais 'sudo' est manquant." >&2
  echo "   Installe-le puis relance le script, par exemple :" >&2
  echo "     su -c 'apt-get update && apt-get install -y sudo'" >&2
  echo "   (ou lance directement le script en root). Arrêt." >&2
  exit 1
fi
require_root_or_sudo

# ────────────────────────────────────────────────────────────────────────
section "2/8 — Vérification & installation des dépendances système"
measure_apt_deps
if [ -z "${APT_NEEDED}" ]; then
  log "Toutes les dépendances système sont déjà présentes — rien à installer."
else
  echo "  Paquets apt manquants :${APT_NEEDED}"
  if confirm "Installer ces paquets via apt (sudo, téléchargement requérant réseau) ?"; then
    sudo apt-get update -y
    sudo apt-get install -y ${APT_NEEDED}
    measure_apt_deps
    if [ -n "${APT_NEEDED}" ]; then
      echo "ERREUR: certains paquets n'ont pas pu être installés :${APT_NEEDED}" >&2
      echo "  Corrige et relance le script." >&2
      exit 1
    fi
    log "Paquets installés."
  else
    echo "  ❌ Installe-les manuellement, puis relance le script."
    echo "  Requis :${APT_NEEDED}"
    exit 1
  fi
fi
log "Versions: git $(git --version | awk '{print $3}'), ffmpeg $(ffmpeg -version | head -n1 | awk '{print $3}')"

# ────────────────────────────────────────────────────────────────────────
section "3/8 — Node.js ≥ ${NODE_MAJOR} (via nvm)"
if command -v node >/dev/null 2>&1 && [ "$(node -v | sed 's/^v//' | cut -d. -f1)" -ge "${NODE_MAJOR}" ]; then
  log "Node déjà présent: $(node -v) — OK."
else
  if confirm "Node/nvm absents — télécharger et installer Node ${NODE_MAJOR} via nvm ?"; then
    export NVM_DIR="${HOME}/.nvm"
    if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
      log "Installation de nvm..."
      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    fi
    . "${NVM_DIR}/nvm.sh"
    log "Installation de Node ${NODE_MAJOR} (nvm)..."
    nvm install "${NODE_MAJOR}"
    nvm alias default "${NODE_MAJOR}" >/dev/null
  else
    echo "  ❌ Node ≥ ${NODE_MAJOR} requis — installe-le puis relance." >&2
    exit 1
  fi
fi
# Met node/npm/npx sur le PATH (nvm, shell non interactif)
export NVM_DIR="${HOME}/.nvm"
if [ -s "${NVM_DIR}/nvm.sh" ]; then . "${NVM_DIR}/nvm.sh"; fi
if command -v node >/dev/null 2>&1; then
  log "Node disponible: $(node -v), npm $(npm -v)."
else
  echo "ERREUR: node introuvable après installation nvm." >&2; exit 1
fi

# ────────────────────────────────────────────────────────────────────────
section "4/8 — opencode"
if [ -x "${HOME}/.opencode/bin/opencode" ]; then
  log "opencode déjà installé: $("${HOME}/.opencode/bin/opencode" --version) — OK."
else
  if confirm "opencode absent — télécharger et installer (script officiel opencode.ai) ?"; then
    log "Installation via le script officiel (https://opencode.ai/install)..."
    curl -fsSL https://opencode.ai/install | bash
  else
    echo "  ❌ opencode requis — installe-le puis relance." >&2
    exit 1
  fi
fi
export PATH="${HOME}/.opencode/bin:${PATH}"
opencode --version

# Configuration opencode (provider Agnes, identique à la machine source)
OPTCFG="${HOME}/.config/opencode/opencode.jsonc"
if [ ! -f "${OPTCFG}" ]; then
  mkdir -p "${HOME}/.config/opencode"
  cat > "${OPTCFG}" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "agnes": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Agnes AI",
      "options": {
        "baseURL": "https://apihub.agnes-ai.com/v1",
        "apiKey": "{env:AGNES_API_KEY}"
      },
      "models": {
        "agnes-2.5-flash": {
          "name": "Agnes 2.5 Flash",
          "tool_call": true,
          "temperature": true,
          "limit": { "context": 512000, "output": 65536 }
        },
        "agnes-2.0-flash": {
          "name": "Agnes 2.0 Flash",
          "tool_call": true,
          "temperature": true
        },
        "agnes-1.5-flash": {
          "name": "Agnes 1.5 Flash",
          "tool_call": true
        }
      }
    }
  }
}
JSON
  log "Config opencode écrite: ${OPTCFG}"
else
  log "Config opencode déjà présente: ${OPTCFG} — inchangée."
fi

# ────────────────────────────────────────────────────────────────────────
#  Le repo est PRIVÉ : il faut la clé SSH AVANT de pouvoir le charger.
# ────────────────────────────────────────────────────────────────────────
section "5/8 — Liaison GitHub (deux Deploy keys : main + repo)"
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

# Clé A — identité 'main' : pousse les storyboards vers openmontage_story
if [ ! -f "${SSH_KEY_MAIN}" ]; then
  if confirm "Générer la clé 'main' (${SSH_KEY_MAIN}) pour pousser les storyboards vers openmontage_story ?"; then
    ssh-keygen -t ed25519 -C "openmontage_story" -f "${SSH_KEY_MAIN}" -N "" -q
    log "Clé 'main' générée: ${SSH_KEY_MAIN}"
  else
    echo "  ❌ La clé 'main' est nécessaire pour pousser les storyboards sur openmontage_story." >&2
    exit 1
  fi
else
  log "Clé 'main' déjà présente: ${SSH_KEY_MAIN}"
fi

# Clé B — identité 'repo' : fetch du projet + push du setup vers main
if [ ! -f "${SSH_KEY}" ]; then
  if confirm "Générer la clé 'repo' (${SSH_KEY}) pour l'accès au projet et le push du setup vers main ?"; then
    ssh-keygen -t ed25519 -C "openmontage_setup" -f "${SSH_KEY}" -N "" -q
    log "Clé 'repo' générée: ${SSH_KEY}"
  else
    echo "  ❌ La clé 'repo' est nécessaire pour accéder au repo privé." >&2
    exit 1
  fi
else
  log "Clé 'repo' déjà présente: ${SSH_KEY}"
fi

# Alias SSH dans ~/.ssh/config (idempotents)
CFG="${HOME}/.ssh/config"
ensure_alias() { # ensure_alias <alias> <clé>
  if [ ! -f "${CFG}" ] || ! grep -qE "^Host[[:space:]]+${1}([[:space:]]|$)" "${CFG}"; then
    cat >> "${CFG}" <<CFG

Host ${1}
    HostName github.com
    User git
    IdentityFile ${2}
    IdentitiesOnly yes
CFG
    log "Alias SSH '${1}' ajouté au config."
  else
    log "Alias SSH '${1}' déjà présent — inchangé."
  fi
}
ensure_alias "${GITHUB_MAIN_ALIAS}" "${SSH_KEY_MAIN}"
ensure_alias "${GITHUB_HOST_ALIAS}" "${SSH_KEY}"
chmod 600 "${CFG}" 2>/dev/null || true

echo
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  AJOUTE CES DEUX CLÉS PUBLIQUES SUR GITHUB                   │"
echo "│  · 'openmontage_setup' → yakuzas2345/openmontage_setup (write) │"
echo "│  · 'openmontage_story' → yakuzas2345/openmontage_story (write) │"
echo "└──────────────────────────────────────────────────────────────┘"
echo
echo "  ➤ CLÉ 'MAIN'  (fetch + push du setup vers main) — alias openmontage_setup"
echo "     → repo yakuzas2345/openmontage_setup — Settings → Deploy keys"
cat "${SSH_KEY}.pub"
echo
echo "  ➤ CLÉ 'MAIN'  (push des storyboards) — alias openmontage_story"
echo "     → repo yakuzas2345/openmontage_story — Settings → Deploy keys"
cat "${SSH_KEY_MAIN}.pub"
echo
echo "Attends d'avoir ajouté LES DEUX clés sur GitHub, puis appuie sur Entrée..."
read -r

# Vérification itérative des clés SSH — boucle tant que les 2 clés ne sont pas validées
_check_ssh() {
  local alias="$1"
  echo "  -> ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes git@$alias"
  ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes git@$alias 2>&1 | grep -q "successfully authenticated"
}

_display_keys() {
  echo ""
  echo "┌──────────────────────────────────────────────────────────────┐"
  echo "│  AJOUTE CES DEUX CLÉS PUBLIQUES SUR GITHUB                   │"
  echo "│  · '${GITHUB_HOST_ALIAS}' → yakuzas2345/openmontage_setup  (write) │"
  echo "│  · '${GITHUB_MAIN_ALIAS}' → yakuzas2345/openmontage_story  (write) │"
  echo "└──────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  ➤ CLÉ '${GITHUB_HOST_ALIAS}' (fetch + push du setup vers main)"
  echo "     → repo yakuzas2345/openmontage_setup — Settings → Deploy keys"
  cat "${SSH_KEY}.pub"
  echo ""
  echo "  ➤ CLÉ '${GITHUB_MAIN_ALIAS}' (push des reproduction scripts)"
  echo "     → repo yakuzas2345/openmontage_story — Settings → Deploy keys"
  cat "${SSH_KEY_MAIN}.pub"
  echo ""
}

# Boucle de vérification : affiche les clés à chaque échec et réessaie
MAX_ATTEMPTS=30
attempt=0
while true; do
  setup_ok=false
  story_ok=false
  
  _check_ssh "${GITHUB_HOST_ALIAS}" && setup_ok=true
  _check_ssh "${GITHUB_MAIN_ALIAS}" && story_ok=true
  
  if ${setup_ok} && ${story_ok}; then
    log "SSH authentifié ✓ (${GITHUB_HOST_ALIAS} + ${GITHUB_MAIN_ALIAS})"
    break
  fi
  
  attempt=$((attempt + 1))
  if [ "${attempt}" -ge "${MAX_ATTEMPTS}" ]; then
    echo "ERREUR: impossible d'authentifier les clés après ${MAX_ATTEMPTS} essais." >&2
    echo "Vérifie que les clés publiques sont bien ajoutées sur les deux repos GitHub." >&2
    exit 1
  fi
  
  echo ""
  echo "⚠ Clés non encore authentifiées (essai ${attempt}/${MAX_ATTEMPTS})..."
  echo "  ${GITHUB_HOST_ALIAS} : $([ ${setup_ok} ] && echo '✓' || echo '✗')"
  echo "  ${GITHUB_MAIN_ALIAS} : $([ ${story_ok} ] && echo '✓' || echo '✗')"
  echo ""
  _display_keys
  echo "Attends d'avoir ajouté les clés sur GitHub, puis appuie sur Entrée pour réessayer..."
  read -r
done

# ────────────────────────────────────────────────────────────────────────
section "6/8 — OpenMontage (initialisation git + récupération + setup)"
mkdir -p "${OPENMONTAGE_DIR}"
cd "${OPENMONTAGE_DIR}"
if [ -d .git ]; then
  log "Repo git déjà initialisé dans ${OPENMONTAGE_DIR} — mise à jour: git pull"
  git remote get-url origin_main >/dev/null 2>&1 \
    || git remote add origin_main "git@${GITHUB_HOST_ALIAS}:${GITHUB_REPO}"
  git remote get-url origin_${BOOTSTRAP_BRANCH} >/dev/null 2>&1 \
    || git remote add origin_${BOOTSTRAP_BRANCH} "git@${GITHUB_MAIN_ALIAS}:${GITHUB_STORY_REPO}"
  git pull --ff-only || log "pull a échoué (ignore — branche locale divergente ?)"
else
  log "Initialisation de git dans ${OPENMONTAGE_DIR} (pas de clone) ..."
  git init -q
  git remote add origin_main "git@${GITHUB_HOST_ALIAS}:${GITHUB_REPO}"
  git remote add origin_${BOOTSTRAP_BRANCH} "git@${GITHUB_MAIN_ALIAS}:${GITHUB_STORY_REPO}"
  log "Récupération de l'historique depuis git@${GITHUB_HOST_ALIAS}:${GITHUB_REPO} ..."
  git fetch origin_main
  git fetch origin_${BOOTSTRAP_BRANCH}
  log "Remotes prêts : 'origin_main' (projet/setup → main) + 'origin_${BOOTSTRAP_BRANCH}' (storyboards)."

  # Si ce script a été téléchargé DANS le futur dossier du repo, il bloquerait
  # le checkout (fichier non suivi en conflit avec la version distante).
  # On le déplace temporairement : le fd d'exécution reste ouvert, donc le
  # script continue de tourner, et la version distante le réécrit proprement.
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  if [ "${SELF}" = "${OPENMONTAGE_DIR}/scripts/setup_ubuntu.sh" ]; then
    mkdir -p "${OPENMONTAGE_DIR}/.bootstrap/"
    mv "${SELF}" "${OPENMONTAGE_DIR}/.bootstrap/setup_ubuntu.sh.running"
    log "Script déplacé en .bootstrap/ pour libérer le checkout ..."
  fi

  # Nouvelle branche locale (JAMAIS 'main') issue de origin_main/main
  if ! git checkout -b "${BOOTSTRAP_BRANCH}" origin_main/main 2>&1; then
    log "Branche '${BOOTSTRAP_BRANCH}' déjà présente — checkout direct."
    if ! git checkout "${BOOTSTRAP_BRANCH}" 2>&1; then
      echo "ERREUR: récupération de la branche '${BOOTSTRAP_BRANCH}' impossible" >&2
      echo "  — un fichier non suivi bloque probablement le checkout." >&2
      echo "  Libère le dossier puis relance." >&2
      exit 1
    fi
  fi
  rm -f "${OPENMONTAGE_DIR}/.bootstrap/setup_ubuntu.sh.running"
  log "Branche locale '${BOOTSTRAP_BRANCH}' (issue de origin_main/main): $(git log --oneline -1)"
  # Branche locale 'main' = miroir du main distant du projet (commits de setup)
  git branch --track main origin_main/main 2>/dev/null \
    || log "Branche locale 'main' déjà présente — laissée telle quelle."
  # Branch setup pointe vers sa propre branche upstream (pas main)
  git branch --set-upstream-to=origin_${BOOTSTRAP_BRANCH}/${BOOTSTRAP_BRANCH} 2>/dev/null \
    || log "Upstream setup '${BOOTSTRAP_BRANCH}' pas encore créé — premier push le créera."
fi

if [ ! -d .venv ]; then
  log "Création du venv (.venv)..."
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
. .venv/bin/activate
python -V

if confirm "Lancer 'make setup' (télécharge deps Python, Remotion, Piper TTS, HyperFrames) ?"; then
  log "make setup ..."
  make setup
fi
if confirm "Lancer 'make install-dev' (outils de test pytest) ?"; then
  log "make install-dev ..."
  make install-dev
fi
log "Setup OpenMontage terminé."

# Pousse la branche de setup vers le repo des storyboards (origin_<branche> / openmontage_story)
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"
if confirm "Pousser la branche '${BRANCH}' sur openmontage_story (origin_${BRANCH}) ?"; then
  if git push -u origin_${BRANCH} "${BRANCH}" 2>&1; then
    log "Branche '${BRANCH}' poussée et suivie (upstream = origin_${BRANCH}/${BRANCH})."
  else
    echo "  ⚠ Le push a échoué — la clé 'openmontage_story' est-elle en Deploy key (write) sur openmontage_story ?" >&2
    echo "    Retente ensuite: git push -u origin_${BRANCH} ${BRANCH}" >&2
    exit 1
  fi
else
  log "Branche '${BRANCH}' non poussée — pousse-la plus tard avec: git push -u origin_${BRANCH} ${BRANCH}"
fi

# ────────────────────────────────────────────────────────────────────────
section "7/8 — Clés API (.env)"
cd "${OPENMONTAGE_DIR}"
if [ -f .env ]; then
  log ".env déjà présent — inchangé."
elif [ -n "${SRC_ENV}" ] && [ -f "${SRC_ENV}" ]; then
  cp "${SRC_ENV}" .env
  log ".env copié depuis ${SRC_ENV}"
else
  cp .env.example .env
  log ".env créé depuis .env.example"
  echo "  ⚠ Ajoute tes clés API dans ${OPENMONTAGE_DIR}/.env : AGNES_API_KEY,"
  echo "    COLOSSYAN_API_KEY, FREESOUND_API_KEY, PEXELS_API_KEY, etc."
fi

# ────────────────────────────────────────────────────────────────────────
section "8/8 — Vérification finale des dépendances"
# shellcheck disable=SC2317
report_runtime_gaps
if [ -z "${GAPS}" ]; then
  log "Tous les outils runtime sont présents ✓"
else
  echo "  ✗ Outils runtime manquants :${GAPS}" >&2
  echo "  Relance le script après les avoir installés." >&2
  exit 1
fi
command -v git   >/dev/null && log "git      : $(git --version | awk '{print $3}')"
command -v ffmpeg >/dev/null && log "ffmpeg   : $(ffmpeg -version | head -n1 | awk '{print $3}')"
command -v node  >/dev/null && log "node     : $(node -v)"
command -v npm   >/dev/null && log "npm      : $(npm -v)"
command -v python3 >/dev/null && log "python3  : $(python3 -V | awk '{print $2}')"

# ────────────────────────────────────────────────────────────────────────
section "Terminé ✓"
echo "  Repo      : ${OPENMONTAGE_DIR}"
echo "  Branche   : $(git -C "${OPENMONTAGE_DIR}" symbolic-ref --short HEAD) (upstream: $(git -C "${OPENMONTAGE_DIR}" rev-parse --abbrev-ref '@{upstream}'))"
echo "  SSH       : git@${GITHUB_HOST_ALIAS} (openmontage_setup: projet/setup) + git@${GITHUB_MAIN_ALIAS} (openmontage_story: storyboards)"
echo "  Node      : $(node -v) / npm $(npm -v)"
echo "  Python    : $("${OPENMONTAGE_DIR}/.venv/bin/python" -V)"
echo "  opencode  : $("${HOME}/.opencode/bin/opencode" --version)"
echo
echo "Pour lancer opencode dans le projet :"
echo "  cd ${OPENMONTAGE_DIR} && opencode"
echo
echo "Garde tes secrets hors de tout commit — .env est gitignoré."

# ────────────────────────────────────────────────────────────────────────
#  Sauvegarde de l'état pour reprise ultérieure
# ────────────────────────────────────────────────────────────────────────
cat > "${HOME}/.openmontage_resume_state" << EOF
STEP1=${STEP1:-done}
STEP2=${STEP2:-done}
STEP3=${STEP3:-done}
STEP4=${STEP4:-done}
STEP5=${STEP5:-done}
STEP6=${STEP6:-done}
EOF

echo ""
echo "💾 État sauvegardé dans ${HOME}/.openmontage_resume_state"
echo "Pour reprendre un setup interrompu: ./setup_ubuntu.sh"
