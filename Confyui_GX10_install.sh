#!/usr/bin/env bash
# Instalador idempotente ComfyUI GB10: instalação completa apenas se ausente;
# numa instalação existente adiciona apenas downloader Hugging Face.
set -Eeuo pipefail
trap 'echo "ERRO na linha $LINENO: $BASH_COMMAND" >&2' ERR
[[ $EUID -ne 0 ]] || { echo 'Executa sem sudo.' >&2; exit 1; }
BASE="${COMFYUI_GB10_DIR:-${COMFYUI_DIR:-$HOME/spark-comfyui}}"
CONTAINER='spark-comfyui'
install_full_comfyui() (
REPO_URL='https://github.com/bjarkebolding/spark-comfyui.git'
INSTALL_DIR="$BASE"
PORT="${COMFYUI_PORT:-8188}"
BIND_ADDR="${COMFYUI_BIND_ADDR:-0.0.0.0}"

info() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || fail 'Executa como utilizador normal, sem sudo.'
[[ $(uname -m) == aarch64 ]] || fail 'Este instalador destina-se a Linux ARM64 (aarch64).'
[[ $PORT =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || fail 'COMFYUI_PORT inválida.'
command -v nvidia-smi >/dev/null 2>&1 || fail 'nvidia-smi indisponível. Verifica o driver NVIDIA.'
info 'GPU detetada'
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
nvidia-smi --query-gpu=name --format=csv,noheader | grep -qi 'GB10' || fail 'A GPU não foi identificada como NVIDIA GB10.'

info 'A verificar Git e Docker'
if ! command -v git >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y git ca-certificates
fi
if ! command -v docker >/dev/null 2>&1; then
  info 'Docker não encontrado: a instalar docker.io'
  sudo apt-get update
  sudo apt-get install -y docker.io
  sudo systemctl enable --now docker
fi
if ! docker info >/dev/null 2>&1; then
  if id -nG | grep -qw docker; then
    fail 'Docker indisponível. Confirma: sudo systemctl status docker; docker info'
  fi
  fail "O utilizador não tem acesso ao Docker. Executa: sudo usermod -aG docker \"$USER\"; depois termina sessão e volta a entrar. Volta a executar este instalador."
fi
if ! docker info --format '{{json .Runtimes}}' | grep -qi 'nvidia'; then
  fail 'Runtime NVIDIA não encontrado no Docker. Instala/configura nvidia-container-toolkit antes de continuar.'
fi

info 'A preparar projeto isolado'
if [[ -d "$INSTALL_DIR/.git" ]]; then
  current_origin="$(git -C "$INSTALL_DIR" remote get-url origin)"
  case "$current_origin" in
    "$REPO_URL"|https://github.com/bjarkebolding/spark-comfyui|git@github.com:bjarkebolding/spark-comfyui.git) ;;
    *) fail "O diretório $INSTALL_DIR já contém outro repositório: $current_origin" ;;
  esac
  info 'Repositório existente: não será atualizado automaticamente.'
elif [[ -e "$INSTALL_DIR" ]]; then
  fail "Já existe $INSTALL_DIR mas não é um clone Git. Escolhe outro COMFYUI_GB10_DIR."
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi
[[ -f "$INSTALL_DIR/spark-comfyui.sh" ]] || fail 'Não foi encontrado spark-comfyui.sh.'
chmod u+x "$INSTALL_DIR/spark-comfyui.sh"
cd "$INSTALL_DIR"

info 'A instalar ComfyUI-Manager na pasta persistente de custom_nodes'
NODES_DIR="$INSTALL_DIR/data/custom_nodes"
MANAGER_DIR="$NODES_DIR/ComfyUI-Manager"
mkdir -p "$NODES_DIR"
if [[ -d "$MANAGER_DIR/.git" ]]; then
  info 'ComfyUI-Manager já existe; a preservar alterações locais.'
elif [[ -e "$MANAGER_DIR" ]]; then
  fail "A pasta $MANAGER_DIR já existe mas não é um repositório Git; não será substituída."
else
  git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager.git "$MANAGER_DIR"
fi

info 'A compilar e instalar a imagem ComfyUI específica do GB10'
./spark-comfyui.sh install

info 'A testar CUDA, SageAttention e dependências com o diagnóstico do projeto'
./spark-comfyui.sh doctor

info "A iniciar ComfyUI como serviço Docker na porta $PORT"
PORT="$PORT" BIND_ADDR="$BIND_ADDR" ./spark-comfyui.sh service

info 'A verificar dependências Python do ComfyUI-Manager dentro do contentor'
# Os custom_nodes estão montados no contentor, mas as bibliotecas Python não.
# Reaplica a instalação de dependências em cada execução do instalador.
CONTAINER_NAME='spark-comfyui'
if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  fail "Contentor $CONTAINER_NAME não encontrado após o arranque."
fi
if [[ -f "$MANAGER_DIR/requirements.txt" ]]; then
  if ! docker exec -u root "$CONTAINER_NAME" sh -c 'python -m pip install --disable-pip-version-check -r /opt/ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt'; then
    fail 'Falhou a instalação das dependências do Manager. Consulta docker logs spark-comfyui --tail 100.'
  fi
fi
info 'A reiniciar o contentor para carregar o Manager'
docker restart "$CONTAINER_NAME" >/dev/null
info 'A confirmar que o contentor iniciou'
for _ in $(seq 1 30); do
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == 'true' ]] && break
  sleep 2
done
[[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == 'true' ]] || fail 'O contentor não iniciou após instalar o Manager.'

info 'Estado final'
./spark-comfyui.sh status
printf '\nInstalação concluída.\n'
printf 'Interface: http://IP_DO_ASUS:%s\n' "$PORT"
printf 'Diretório: %s\n' "$INSTALL_DIR"
printf 'Modelos: %s/data/models/\n' "$INSTALL_DIR"
printf 'ComfyUI-Manager: %s/data/custom_nodes/ComfyUI-Manager/\n' "$INSTALL_DIR"
printf 'Nota: as dependências Python do Manager instaladas no contentor podem precisar de reinstalação se a imagem for recriada; volta a executar este script nesse caso.\n'
printf '\nComandos de manutenção:\n'
printf '  cd %q && ./spark-comfyui.sh status\n' "$INSTALL_DIR"
printf '  cd %q && ./spark-comfyui.sh doctor\n' "$INSTALL_DIR"
printf '  cd %q && ./spark-comfyui.sh stop\n' "$INSTALL_DIR"
printf '  cd %q && ./spark-comfyui.sh service\n' "$INSTALL_DIR"
printf '\nSegurança: o ComfyUI não tem autenticação. Mantém a porta acessível apenas numa LAN de confiança.\n'

)

if ! command -v docker >/dev/null 2>&1 || ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo 'ComfyUI não detetado. A iniciar instalação completa para GB10...'
  # Executar instalador integral na primeira instalação.
  install_full_comfyui
else
  echo 'ComfyUI existente detetado. Não será recompilado nem reinstalado.'
fi
[[ -d "$BASE/data/custom_nodes" && -d "$BASE/data/models" ]] || { echo "Pastas persistentes não encontradas em $BASE" >&2; exit 1; }
command -v docker >/dev/null || { echo 'Docker não encontrado.' >&2; exit 1; }
docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "Contentor $CONTAINER não encontrado." >&2; exit 1; }
MOUNT=$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/opt/ComfyUI/custom_nodes"}}{{.Source}}{{end}}{{end}}')
[[ "$MOUNT" == "$(realpath "$BASE/data/custom_nodes")" ]] || { echo "Volume custom_nodes inesperado: $MOUNT" >&2; exit 1; }
PLUGIN="$BASE/data/custom_nodes/ComfyUI-HF-Downloader-GB10"
mkdir -p "$PLUGIN/web"
cat > "$PLUGIN/__init__.py" <<'PY'
"""Download controlado de modelos Hugging Face para pastas do ComfyUI."""
import asyncio
import os
import re
from pathlib import Path
from urllib.parse import urlparse, unquote

from aiohttp import web, ClientSession, ClientTimeout
from server import PromptServer
import folder_paths

WEB_DIRECTORY = "./web"
NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}

ALLOWED_FOLDERS = {
    "checkpoints": "checkpoints", "loras": "loras", "vae": "vae",
    "text_encoders": "text_encoders", "diffusion_models": "diffusion_models",
    "controlnet": "controlnet", "clip_vision": "clip_vision",
    "upscale_models": "upscale_models", "embeddings": "embeddings",
}
LOCK = asyncio.Lock()
STATUS = {"state": "idle", "name": "", "received": 0, "total": None, "message": ""}
MAX_BYTES = 100 * 1024**3


def model_url(raw):
    u = urlparse(raw.strip())
    if u.scheme != "https" or u.hostname != "huggingface.co" or u.port not in (None, 443) or u.username or u.password:
        raise ValueError("Apenas URLs HTTPS de huggingface.co são permitidos")
    parts = [unquote(p) for p in u.path.split("/") if p]
    if len(parts) < 5 or parts[2] not in ("blob", "resolve") or parts[3] != "main":
        raise ValueError("URL inválido. Usa um link /blob/main/... ou /resolve/main/...")
    name = parts[-1]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.(safetensors|ckpt|pt|pth|bin)", name, flags=re.I):
        raise ValueError("Nome ou extensão de modelo não permitidos")
    from urllib.parse import quote
    safe_path = "/".join(quote(p, safe="") for p in parts[:2] + ["resolve", "main"] + parts[4:])
    return "https://huggingface.co/" + safe_path, name


@PromptServer.instance.routes.get("/hf-gb10/status")
async def status(_request):
    return web.json_response(STATUS)


@PromptServer.instance.routes.post("/hf-gb10/download")
async def download(request):
    if LOCK.locked():
        return web.json_response({"error": "Já existe um download em curso"}, status=409)
    try:
        data = await request.json()
        folder = data.get("folder", "")
        if folder not in ALLOWED_FOLDERS:
            raise ValueError("Pasta de destino inválida")
        url, name = model_url(data.get("url", ""))
    except (ValueError, TypeError, AttributeError) as e:
        return web.json_response({"error": str(e)}, status=400)

    # Pasta controlada pelo ComfyUI (pode existir mais do que uma localização configurada).
    destinations = folder_paths.get_folder_paths(ALLOWED_FOLDERS[folder])
    if not destinations:
        return web.json_response({"error": "Pasta não configurada"}, status=400)
    target_dir = Path(destinations[0]).resolve()
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / name
    if target.exists():
        return web.json_response({"error": "O ficheiro já existe; não será substituído"}, status=409)

    async def job():
        async with LOCK:
            STATUS.update(state="downloading", name=name, received=0, total=None, message="")
            temp = target.with_name(target.name + ".part")
            try:
                if temp.exists():
                    raise ValueError("Já existe um download parcial com este nome; verifica antes de tentar novamente")
                timeout = ClientTimeout(total=None, connect=45, sock_read=180)
                async with ClientSession(timeout=timeout, trust_env=False) as session:
                    async with session.get(url, allow_redirects=True, max_redirects=5) as response:
                        response.raise_for_status()
                        # Redirecionamentos para CDN Hugging Face são normais; só a URL inicial é aceite pelo utilizador.
                        size = response.content_length
                        if size and size > MAX_BYTES:
                            raise ValueError("Ficheiro superior a 100 GiB")
                        STATUS["total"] = size
                        with open(temp, "xb") as out:
                            async for chunk in response.content.iter_chunked(1024 * 1024):
                                STATUS["received"] += len(chunk)
                                if STATUS["received"] > MAX_BYTES:
                                    raise ValueError("Ficheiro superior a 100 GiB")
                                out.write(chunk)
                if temp.stat().st_size == 0:
                    raise ValueError("Download vazio")
                os.rename(temp, target)
                STATUS.update(state="done", message="Concluído")
            except Exception as exc:
                STATUS.update(state="error", message=str(exc)[:400])
                try:
                    temp.unlink(missing_ok=True)
                except OSError:
                    pass

    asyncio.create_task(job())
    return web.json_response({"ok": True, "name": name, "folder": folder}, status=202)
PY
cat > "$PLUGIN/web/hf_downloader.js" <<'JS'
import { app } from "/scripts/app.js";

app.registerExtension({
  name: "gb10.huggingface.downloader",
  async setup() {
    const button = document.createElement("button");
    button.textContent = "HF Download";
    button.title = "Descarregar modelos Hugging Face para o servidor ComfyUI";
    button.style.cssText = "position:fixed;bottom:20px;right:20px;z-index:9998;padding:10px 14px;border-radius:9px;background:#245b82;color:white;border:1px solid #5687aa;cursor:pointer;font-weight:600";
    document.body.appendChild(button);
    let timer;
    button.onclick = () => {
      if (document.getElementById("hf-gb10-dialog")) return;
      const overlay = document.createElement("div");
      overlay.id = "hf-gb10-dialog";
      overlay.style.cssText = "position:fixed;inset:0;z-index:9999;background:#0009;display:flex;align-items:center;justify-content:center";
      const panel = document.createElement("div");
      panel.style.cssText = "background:#222;color:#fff;border:1px solid #666;border-radius:12px;padding:24px;width:min(600px,92vw);font:14px sans-serif;box-shadow:0 10px 50px #0008";
      const heading = document.createElement("h3"); heading.textContent = "Download Hugging Face → ComfyUI";
      const hint = document.createElement("p"); hint.textContent = "Cola o URL do ficheiro no Hugging Face e escolhe a pasta de destino.";
      const url = document.createElement("input"); url.type="url"; url.placeholder="https://huggingface.co/.../blob/main/...safetensors"; url.style.cssText="box-sizing:border-box;width:100%;padding:10px;margin:8px 0;background:#333;color:white;border:1px solid #666;border-radius:5px";
      const folder = document.createElement("select"); folder.style.cssText="padding:9px;margin:8px 0;background:#333;color:white;border:1px solid #666;border-radius:5px;width:100%";
      for (const value of ["diffusion_models","loras","vae","text_encoders","checkpoints","controlnet","clip_vision","upscale_models","embeddings"]) { const opt=document.createElement("option"); opt.value=value; opt.textContent=value; folder.appendChild(opt); }
      const state = document.createElement("p"); state.style.cssText="min-height:2em;white-space:pre-wrap;word-break:break-word";
      const go = document.createElement("button"); go.textContent="Descarregar para o servidor"; go.style.cssText="padding:9px 12px;margin-right:12px;cursor:pointer";
      const close = document.createElement("button"); close.textContent="Fechar"; close.style.cssText="padding:9px 12px;cursor:pointer";
      close.onclick=()=>{clearInterval(timer);overlay.remove();};
      go.onclick=async()=>{
        try {
          const response=await fetch("/hf-gb10/download",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({url:url.value,folder:folder.value})});
          const data=await response.json();
          if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
          state.textContent=`A descarregar ${data.name}...`;
        } catch(e) { state.textContent="Erro: "+e.message; }
      };
      panel.append(heading,hint,url,folder,go,close,state); overlay.appendChild(panel); document.body.appendChild(overlay);
      const update=async()=>{
        try {const r=await fetch("/hf-gb10/status");if(!r.ok)return;const s=await r.json();if(s.state==="idle")return;
          const mb=(s.received/1048576).toFixed(1);const total=s.total?` / ${(s.total/1048576).toFixed(1)} MiB`:"";
          state.textContent=`${s.name}: ${s.state} — ${mb}${total}${s.message?" — "+s.message:""}`;
        }catch(e){}
      };
      timer=setInterval(update,1200);update();
    };
  }
});
JS
python3 -m py_compile "$PLUGIN/__init__.py"
echo "Plugin instalado em $PLUGIN"
echo "A reiniciar apenas o contentor $CONTAINER (sem recompilar a imagem)..."
docker restart "$CONTAINER" >/dev/null
sleep 4
if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != true ]]; then
  echo 'O contentor não arrancou. Logs:' >&2
  docker logs "$CONTAINER" --tail 80 >&2
  exit 1
fi
echo 'Instalação terminada. Atualiza a interface ComfyUI (Ctrl+F5) e procura o botão HF Download.'
echo 'Segurança: a interface ComfyUI não tem autenticação; mantém a porta 8188 restrita à LAN de confiança.'
