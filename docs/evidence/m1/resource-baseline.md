# M1 resource baseline (K3s idle, no workloads)

Measured 2026-11-24 right after the K3s install (v1.36.6+k3s1, bundled Traefik, ServiceLB, local-path, metrics-server, CoreDNS).
Sample taken after all bundled Deployments were Available.

The Lima VM has 2 CPU / 12 GiB / 100 GiB, the same shape as the future OCI A1 target, so the section 15.1 comparison is valid for sizing.
CPU performance differs between Apple Silicon (vz) and OCI Ampere A1 and is recorded here only, not compared.

## free -m (guest)
```
               total        used        free      shared  buff/cache   available
Mem:           11934        1096        9287           1        1755       10838
Swap:              0           0           0
```

## nproc (guest)
```
2
```

## kubectl top node
```
NAME             CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)   
lima-secure-ax   144m         7%       955Mi           8%          
```
