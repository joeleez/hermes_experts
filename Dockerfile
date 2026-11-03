# 官方映像 + Feishu SDK + YAML
#
# 為什麼要裝 lark-oapi：官方映像不含它，沒裝的話 gateway 只會說
# "adapter creation failed"，看不出真正原因是模組缺失。
#
# 為什麼要裝 pyyaml：seed-agent.sh 用它讀 expert.yml / 寫 identity.yaml，
# 而 stable 映像的 .venv 沒有 pip，也沒有 pyyaml（2026-10 版實測）。
FROM nousresearch/hermes-agent:latest

RUN /opt/hermes/.venv/bin/python -m ensurepip --upgrade \
 && /opt/hermes/.venv/bin/python -m pip install --no-cache-dir lark-oapi pyyaml \
 && /opt/hermes/.venv/bin/python -c "import lark_oapi, yaml; print('lark-oapi + pyyaml OK')"
