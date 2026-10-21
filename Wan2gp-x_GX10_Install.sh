#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERRO na linha ${LINENO}. Consulta a mensagem acima." >&2' ERR

if [[ ${EUID} -eq 0 ]]; then
  echo 'Executa este instalador como utilizador normal (sem sudo).' >&2
  exit 1
fi
if [[ $(uname -s) != Linux || $(uname -m) != aarch64 ]]; then
  echo 'Este instalador destina-se ao Ubuntu Linux ARM64 (aarch64).' >&2
  exit 1
fi
if ! command -v sudo >/dev/null; then
  echo 'sudo não está disponível.' >&2
  exit 1
fi

REPO_URL='https://github.com/autojake/Wan2GP-X.git'
INSTALL_DIR="${HOME}/Wan2GP-X"
UV_BIN="${HOME}/.local/bin/uv"
SERVICE="wan2gpx-${USER}.service"
STARTER="${HOME}/start-wan2gpx.sh"

echo '==> A instalar dependências do sistema'
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git curl ca-certificates build-essential pkg-config cmake ninja-build \
  ffmpeg libgl1 libglib2.0-0 libsndfile1 libportaudio2 espeak-ng

echo '==> A instalar uv no perfil do utilizador'
if ! command -v uv >/dev/null 2>&1 && [[ ! -x "$UV_BIN" ]]; then
  curl -LsSf https://astral.sh/uv/install.sh -o /tmp/wan2gpx-uv-install.sh
  sh /tmp/wan2gpx-uv-install.sh
fi
if command -v uv >/dev/null 2>&1; then
  UV_BIN="$(command -v uv)"
fi
if [[ ! -x "$UV_BIN" ]]; then
  echo 'Não foi possível encontrar o executável uv.' >&2
  exit 1
fi
"$UV_BIN" --version

echo '==> A preparar o repositório Wan2GP-X'
if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo 'Repositório já existe. Não será atualizado automaticamente para evitar alterar ficheiros locais.'
elif [[ -e "$INSTALL_DIR" ]]; then
  echo "O caminho $INSTALL_DIR existe mas não é um repositório Git. Interrompido para não sobrescrever dados." >&2
  exit 1
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
if [[ ! -f pyproject.toml || ! -f gb10-wgp.py ]]; then
  echo 'Ficheiros esperados do fork não encontrados.' >&2
  exit 1
fi

echo '==> A reconstruir configuração uv a partir da versão Git original'
BACKUP_DIR="${HOME}/.local/share/wan2gpx-config-backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp pyproject.toml "$BACKUP_DIR/pyproject.toml"
if [[ -f uv.lock ]]; then cp uv.lock "$BACKUP_DIR/uv.lock"; fi
if ! git show HEAD:pyproject.toml > "$BACKUP_DIR/pyproject.original.toml"; then
  echo 'Não foi possível obter o pyproject.toml original do Git.' >&2
  exit 1
fi
python3 - "$BACKUP_DIR/pyproject.original.toml" "$INSTALL_DIR/pyproject.toml" <<'PYCONFIG'
from pathlib import Path
import sys, tomllib
source, target = map(Path, sys.argv[1:])
s = source.read_text()
base = tomllib.loads(s)
assert base['project']['name'] == 'wan2gp', 'Projeto inesperado'
assert any(x.startswith('torchcodec==0.10.0') for x in base['project']['dependencies']), 'TorchCodec inesperado'
assert 'pytorch-cu130' in [x['name'] for x in base['tool']['uv']['index']], 'Índice cu130 não encontrado'
start = s.index('[tool.uv]')
end = s.index('\n[', start + len('[tool.uv]'))
s = s[:start] + '[tool.uv]\nenvironments = ["sys_platform == \'linux\' and platform_machine == \'aarch64\'"]\n' + s[end:]
header = '[tool.uv.sources]'
assert header in s
s = s.replace(header, header + '\ntorchcodec = { index = "pytorch-cu130" }', 1)
parsed = tomllib.loads(s)
assert parsed['tool']['uv']['environments'] == ["sys_platform == 'linux' and platform_machine == 'aarch64'"]
assert parsed['tool']['uv']['sources']['torchcodec']['index'] == 'pytorch-cu130'
target.write_text(s)
print('TOML reconstruído e validado para Linux ARM64.')
PYCONFIG
rm -f uv.lock
echo "Cópias de segurança: $BACKUP_DIR"

echo '==> A instalar dependências ARM64/GB10 (pode demorar)'
"$UV_BIN" sync --extra dgx-spark

echo '==> A validar o ambiente Python e GPU'
"$UV_BIN" run --no-sync python - <<'PY'
import platform
import torch
print('Arquitetura:', platform.machine())
print('PyTorch:', torch.__version__)
print('CUDA disponível:', torch.cuda.is_available())
if not torch.cuda.is_available():
    raise SystemExit('CUDA não está disponível no ambiente do Wan2GP-X.')
print('GPU:', torch.cuda.get_device_name(0))
print('Compute capability:', torch.cuda.get_device_capability(0))
print('Teste CUDA:', torch.randn(16, device='cuda').sum().item())
PY

echo '==> A criar comando de arranque'
cat > "$STARTER" <<SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
cd "${INSTALL_DIR}"
exec "${UV_BIN}" run --no-sync gb10-wgp.py --listen --server-name 0.0.0.0 --server-port 7860 --attention sdpa
SCRIPT
chmod 755 "$STARTER"

echo '==> A configurar serviço systemd'
SERVICE_FILE="/etc/systemd/system/${SERVICE}"
TEMP_SERVICE="$(mktemp)"
cat > "$TEMP_SERVICE" <<UNIT
[Unit]
Description=Wan2GP-X (ASUS GB10 / ARM64)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER}
Group=$(id -gn)
WorkingDirectory=${INSTALL_DIR}
Environment=HOME=${HOME}
Environment=PATH=${HOME}/.local/bin:/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin
Environment=PYTHONUNBUFFERED=1
ExecStart=${STARTER}
Restart=on-failure
RestartSec=15
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
UNIT
sudo install -m 644 "$TEMP_SERVICE" "$SERVICE_FILE"
rm -f "$TEMP_SERVICE"
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE"

echo
echo 'Instalação concluída. O serviço foi iniciado (o carregamento inicial pode demorar).'
echo "Serviço: ${SERVICE}"
echo "Diretório: ${INSTALL_DIR}"
echo 'Interface: http://IP_DO_ASUS:7860'
echo "Estado: sudo systemctl status ${SERVICE}"
echo "Logs: sudo journalctl -u ${SERVICE} -f"
echo 'Nota: o instalador não abre automaticamente a firewall nem configura autenticação.'
echo 'Acede apenas numa rede local de confiança, ou protege o acesso com autenticação/VPN.'
