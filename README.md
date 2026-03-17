## GDDRHammer: Greatly Disturbing DRAM Rows — Cross-Component Rowhammer Attacks from Modern GPUs

These are the artifacts for the research paper “GDDRHammer: Greatly Disturbing DRAM Rows — Cross-Component Rowhammer Attacks from Modern GPUs” that is to appear at IEEE Security & Privacy 2026.

Our work develops advanced techniques for dramatically amplifying Rowhammer on modern GDDR6-based GPUs. By utilizing the inherent parallelism in GPUs and developing new techniques for bypassing Rowhammer mitigations on GPUs, we are able to produce roughly 100 bit flips per DRAM bank on average. We also shows the impact of Rowhammer on GPUs by demonstrating the first GPU-to-CPU Rowhammer exploit, with a practical end-to-end attack wherein bit flips in the GPU's memory result in arbitrary read and write access to all of the host CPU's memory. 




## Artifact Overview

This repository contains the artifacts of our work:


- **Rowhammering GPUs** (`rowhammer`)
As we explain in §4 (Rowhammering GPUs), we designed a double-sided multibank
hammering pattern with a synchronized activation sequence that amplifies Rowhammer on GDDR6 memory. This artifact contains the complete rowhammer code, enabling simple reproduction of our results.

- **End-to-End Exploit** (`exploit`)
We show in §6 (Hijacking CPU Memory Via the GPU) that an attacker can practically use Rowhammer on GPU memory to gain read and write access to all of both GPU and CPU memory, thereby allowing the attacker to gain root privileges and completely subvert the system. This artifact contains a sample end-to-end exploit with usable flips.

