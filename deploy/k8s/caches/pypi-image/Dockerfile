# fleet-pypi's image (#3548): devpi-server + devpi-client on python, nothing else.
# Build outside CN and push to the cluster's registry:
#   docker build --platform linux/amd64 -t registry.cn-shenzhen.aliyuncs.com/24haowan/fleet-devpi:6.20.3 deploy/k8s/caches/pypi-image
FROM python:3.13-slim
ARG DEVPI_SERVER=6.20.3 DEVPI_CLIENT=7.3.0
RUN pip install --no-cache-dir "devpi-server==$DEVPI_SERVER" "devpi-client==$DEVPI_CLIENT" \
    && devpi-server --version && devpi --version
USER 65534:65534
