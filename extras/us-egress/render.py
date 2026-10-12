#!/usr/bin/env python3
"""Render the reverse gateway behind the existing hub TLS ingress; no new LB."""
import argparse
import base64
import hashlib
import json
import ipaddress
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--image", required=True)
p.add_argument("--wheel", required=True, type=Path)
p.add_argument("--namespace", default="fleet-workers")
p.add_argument("--host", required=True)
p.add_argument("--pod-cidr", required=True)
p.add_argument("--tls-secret", default="")
a = p.parse_args()
if "@sha256:" not in a.image:
    p.error("pin the image digest")
try:
    pod_cidr = str(ipaddress.ip_network(a.pod_cidr, strict=True))
except ValueError:
    p.error("--pod-cidr must be a strict Pod CIDR")
here = Path(__file__).resolve().parent
program = (here / "us-egress.py").read_text()
wheel = a.wheel.read_bytes()
if hashlib.sha256(wheel).hexdigest() != "dc284bbc8d7c78a6c69e0c7325ab46ee5e40bb4d50e494d8131a07ef47500e9e":
    p.error("use the verified websockets-12.0-py3-none-any.whl from PyPI")
name = "fleet-us-egress"
checksum = hashlib.sha256(program.encode() + wheel).hexdigest()
def obj(kind, spec=None, **kw):
    o = {"apiVersion": "v1", "kind": kind,
         "metadata": {"name": name, "namespace": a.namespace}}
    if spec is not None:
        o["spec"] = spec
    o.update(kw)
    return o
cm = obj("ConfigMap", data={"us-egress.py": program},
         binaryData={"websockets.whl": base64.b64encode(wheel).decode()})
dep = obj("Deployment", {
    "replicas": 1, "revisionHistoryLimit": 3,
    "strategy": {"type": "RollingUpdate", "rollingUpdate":{"maxUnavailable":0,"maxSurge":1}},
    "selector":{"matchLabels":{"app":name}},
    "template":{
        "metadata":{"labels":{"app":name},"annotations":{"checksum/program":checksum}},
        "spec":{
            "automountServiceAccountToken":False,
            "securityContext":{"runAsUser":65534,"runAsGroup":65534,"runAsNonRoot":True,
                               "seccompProfile":{"type":"RuntimeDefault"}},
            "initContainers":[{
                "name":"dependency","image":a.image,
                "command":["python3","-I","-c",
                           "import zipfile; zipfile.ZipFile('/program/websockets.whl').extractall('/deps')"],
                "volumeMounts":[{"name":"program","mountPath":"/program","readOnly":True},
                                {"name":"deps","mountPath":"/deps"}],
                "securityContext":{"allowPrivilegeEscalation":False,"readOnlyRootFilesystem":True,
                                   "capabilities":{"drop":["ALL"]}}
            }],
            "containers":[{
                "name":"gateway","image":a.image,
                "command":["python3","/program/us-egress.py","gateway"],
                "env":[{"name":"PYTHONPATH","value":"/deps"},{"name":"PYTHONDONTWRITEBYTECODE","value":"1"},
                       {"name":"FLEET_US_EGRESS_SOURCES","value":pod_cidr},
                       {"name":"FLEET_US_EGRESS_LISTEN","value":"0.0.0.0:3128"},
                       {"name":"FLEET_US_EGRESS_WS_LISTEN","value":"0.0.0.0:8090"},
                       {"name":"FLEET_US_EGRESS_TOKEN","valueFrom":{"secretKeyRef":{"name":name,"key":"token"}}}],
                "ports":[{"name":"connect","containerPort":3128},{"name":"reverse","containerPort":8090}],
                # Ingress must keep routing new connectors during an outage.
                # /healthz separately reports whether US transport is available.
                "readinessProbe":{"httpGet":{"path":"/livez","port":"reverse"},"periodSeconds":5},
                "livenessProbe":{"httpGet":{"path":"/livez","port":"reverse"},"periodSeconds":20},
                "resources":{"requests":{"cpu":"20m","memory":"64Mi"},"limits":{"cpu":"1","memory":"256Mi"}},
                "securityContext":{"allowPrivilegeEscalation":False,"readOnlyRootFilesystem":True,
                                   "capabilities":{"drop":["ALL"]}},
                "volumeMounts":[{"name":"program","mountPath":"/program","readOnly":True},
                                {"name":"deps","mountPath":"/deps","readOnly":True}]
            }],
            "volumes":[{"name":"program","configMap":{"name":name}},
                       {"name":"deps","emptyDir":{"sizeLimit":"16Mi"}}]
        }
    }
})
dep["apiVersion"]="apps/v1"
svc = obj("Service", {"selector":{"app":name},"publishNotReadyAddresses":True,
                     "ports":[{"name":"connect","port":3128,"targetPort":"connect"},
                              {"name":"reverse","port":8090,"targetPort":"reverse"}]})
# CONNECT remains closed until an authenticated US connector is available.
ing = obj("Ingress", {
    "ingressClassName":"nginx",
    "tls":[{"hosts":[a.host],"secretName":a.tls_secret}] if a.tls_secret else [],
    "rules":[{"host":a.host,"http":{"paths":[{
        "path":"/_fleet/us-egress","pathType":"Exact",
        "backend":{"service":{"name":name,"port":{"name":"reverse"}}}
    }]}}]
})
ing["apiVersion"]="networking.k8s.io/v1"
ing["metadata"]["annotations"]={
    "nginx.ingress.kubernetes.io/proxy-read-timeout":"900",
    "nginx.ingress.kubernetes.io/proxy-send-timeout":"900",
    "nginx.ingress.kubernetes.io/proxy-buffering":"off",
    "nginx.ingress.kubernetes.io/ssl-redirect":"true"
}
print(json.dumps({"apiVersion":"v1","kind":"List","items":[cm,dep,svc,ing]}))
