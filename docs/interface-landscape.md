<!-- SPDX-License-Identifier: GPL-2.0-only -->
<!-- Design/roadmap reference: which modem control/datapath/transport
     interfaces exist in the market and how wwand's architecture maps
     onto them. Informs the QMI+MBIM-first-class, control/datapath/
     transport-separated design (see architecture.md). Not a per-firmware
     feature matrix — exact USB compositions vary by module/firmware. -->

# WWAN modem interface landscape

wwand is designed to support multiple modem control/data-plane interfaces. The current modem market can broadly be divided into Qualcomm/QMI-oriented devices and standards-based MBIM-oriented devices.

## Modem manufacturer / interface matrix

| Manufacturer | Current example modules | USB | QMI | MBIM | NCM | PCIe / MHI | Preferred interface |
|---|---|---:|---:|---:|---:|---:|---|
| **Quectel** | RG650E, RM520N | Yes | **Yes** | Yes | Some | **Yes** | **QMI / QMAP** |
| **Sierra Wireless / Semtech** | EM9291/EM9293, EM9191 | Yes | Yes | **Yes** | – | **Yes / MHI** | **MBIM** |
| **Fibocom** | FM160, FM350, FM190 | Yes | Yes* | **Yes** | Some | Yes | **MBIM** |
| **Telit Cinterion** | FN990, FE990 | Yes | Yes* | **Yes** | – | Some | **MBIM** |
| **SIMCom** | SIM8200, SIM8262, SIM8270 | Yes | **Yes** | Yes | Some | Some | **QMI** |
| **Meig** | SRM825L, SRM815 | Yes | **Yes** | Some | Some | Some | **QMI** |
| **u-blox** | LEXI-R52 / R52 | Yes | – | **Yes** | – | Some | **MBIM** |

\* Availability depends on the exact module, firmware and USB composition.

## 1. Quectel

Quectel is particularly relevant for wwand because its Qualcomm-based 4G/5G modules expose a mature QMI/QMAP/RmNet stack.

Examples include:

- RG650E
- RM520N
- RM551E
- other Qualcomm-based 5G M.2 modules

Typical interfaces include:

```text
USB
 ├── QMI
 ├── MBIM
 ├── QRTR
 └── AT

PCIe
 ├── MHI
 ├── QMI
 ├── MBIM
 ├── QRTR
 └── AT
```

The important point for wwand is that QMI is not limited to legacy LTE devices. It remains a relevant control/data-plane interface for current Qualcomm 5G modules.

Quectel devices are therefore an important target for:

```text
QMI
QMAP
RmNet
QRTR
MHI
```

### wwand relevance

**QMI: very high**

**MBIM: high**

**QMAP/RmNet: very high**

**PCIe/MHI: high**

Quectel should be considered one of the primary reference implementations when validating the QMI backend.

---

## 2. Sierra Wireless / Semtech

Sierra Wireless, now part of Semtech, represents a somewhat different direction.

Examples:

- EM9191
- EM9291
- EM9293

These modules support Qualcomm-based interfaces including QMI/RmNet, but Sierra increasingly recommends MBIM as the generic Linux host interface.

Typical Linux path:

```text
5G modem
   |
   +-- USB
   |
   +-- cdc_mbim
   |
   +-- wwan0
```

Rather than:

```text
5G modem
   |
   +-- QMI/RmNet
   |
   +-- rmnet
```

QMI remains useful and available, particularly for Qualcomm-specific functionality, but MBIM is increasingly the preferred generic host interface.

Newer high-performance modules also use PCIe/MHI.

### wwand relevance

**MBIM: very high**

**QMI: medium**

**PCIe/MHI: very high**

**NCM: low**

Sierra is therefore an important reason why wwand should have a first-class MBIM backend rather than treating MBIM as a secondary compatibility layer.

---

## 3. Fibocom

Relevant current families include:

- FM160
- FM190
- FM350
- other Qualcomm-based 5G modules

Fibocom exposes multiple USB network/control configurations depending on the module and firmware.

Typical possibilities include:

```text
USB
 ├── MBIM
 ├── QMI
 ├── NCM
 └── AT
```

The exact composition is highly module/firmware dependent.

For generic Linux integration, MBIM is generally the safer standardized target, while QMI remains important for Qualcomm-specific functionality.

### wwand relevance

**MBIM: high**

**QMI: medium**

**NCM: medium**

**PCIe: high**

Fibocom is therefore another strong argument for supporting both QMI and MBIM in wwand.

---

## 4. Telit Cinterion

Current Telit Cinterion 5G families include:

- FN990
- FN990B40
- FE990
- FE990D

These are increasingly high-performance Qualcomm-based 5G modules.

Typical host connectivity includes USB and, depending on the module, PCIe-class interfaces.

The Linux-oriented generic data path is primarily interesting from an MBIM perspective, while Qualcomm-specific functionality may still use QMI.

### wwand relevance

**MBIM: very high**

**QMI: medium**

**NCM: low**

**PCIe/MHI: high**

Telit is another manufacturer where a clean MBIM implementation is valuable.

---

## 5. SIMCom

Relevant 5G families include:

- SIM8200
- SIM8262
- SIM8270

SIMCom's Qualcomm-based modules are strongly associated with:

```text
QMI
QMAP
USB
AT
```

MBIM is also available on some configurations.

For embedded router applications, QMI is therefore an important target.

### wwand relevance

**QMI: high**

**MBIM: medium**

**QMAP: high**

**NCM: medium**

SIMCom is a good secondary reference platform for the QMI backend.

---

## 6. Meig

Relevant examples include:

- SRM825L
- SRM815
- other Qualcomm-based 5G modules

The Qualcomm-oriented data path commonly looks like:

```text
QMI
  |
QMAP
  |
rmnet
```

USB and AT interfaces are also common.

Documentation and firmware configuration vary considerably between modules, so exact capabilities need to be checked per device.

### wwand relevance

**QMI: high**

**QMAP: high**

**MBIM: medium**

**NCM: medium**

Meig is therefore another useful QMI/QMAP validation target.

---

## 7. u-blox

u-blox follows a more standards-oriented approach.

Relevant current 5G products include the R52 family.

For Linux integration, MBIM is the important generic host interface.

The conceptual path is:

```text
u-blox modem
     |
     +-- USB
     |
     +-- MBIM
     |
     +-- cdc_mbim
     |
     +-- wwan0
```

This is fundamentally different from the Qualcomm-specific QMI/RmNet architecture.

### wwand relevance

**MBIM: very high**

**QMI: low / not the primary interface**

**NCM: low**

u-blox therefore provides another strong use case for a clean MBIM implementation.

---

# Overall interface landscape

A simplified view of the current 4G/5G modem market is:

```text
                         QMI                  MBIM

Quectel                 █████                ████
SIMCom                  ████                 ███
Meig                    ████                 ███
Fibocom                 ███                  ████
Telit                   ███                  █████
Sierra/Semtech          ███                  █████
u-blox                  ░░░                  █████
```

This is not intended as a strict feature matrix for every firmware revision. Exact interfaces and USB compositions can vary by module, firmware and carrier SKU.

---

# Implications for wwand

The modem ecosystem effectively creates two major groups.

## Qualcomm / QMI-oriented

```text
Quectel
SIMCom
Meig
```

with:

```text
QMI
QMAP
RmNet
QRTR
MHI
```

being particularly relevant.

## Standards-oriented / MBIM-oriented

```text
Sierra Wireless / Semtech
Telit Cinterion
u-blox
Fibocom
```

with:

```text
MBIM
cdc_mbim
wwan
```

being the important generic Linux path.

---

# Recommended wwand architecture

wwand should therefore not model everything as one generic "modem protocol".

A better abstraction is:

```text
                         wwand
                           |
             +-------------+-------------+
             |                           |
        QMI backend                 MBIM backend
             |                           |
       +-----+------+              +-----+------+
       |            |              |            |
      QMI          QRTR           MBIM       MBIM/QMAP*
       |            |              |            |
     QMAP         QMI          cdc_mbim      vendor/
       |            |              |          specific
     rmnet        rmnet          wwan
```

The exact datapath should remain a separate concept from the modem control protocol.

---

# QMAP should be modelled as a datapath capability

One architectural point is particularly important:

**QMAP should not be modelled as a synonym for QMI.**

QMI is primarily the Qualcomm modem control protocol.

QMAP is a Qualcomm packet aggregation/data-plane mechanism.

Therefore the internal model should preferably distinguish:

```text
Control protocol:
    QMI
    MBIM
    AT
    QRTR

Data transport:
    QMAP
    RmNet
    MBIM
    NCM
    Ethernet-like
    PCIe/MHI
```

This makes it possible to represent future combinations without redesigning the architecture.

For example:

```text
control = QMI
datapath = QMAP
transport = USB
```

or:

```text
control = MBIM
datapath = MBIM
transport = USB
```

or:

```text
control = QMI
datapath = QMAP
transport = PCIe/MHI
```

---

# PCIe / MHI

PCIe/MHI deserves explicit consideration in wwand.

Modern high-end Qualcomm 5G modules increasingly support:

```text
PCIe
  |
  +-- MHI
       |
       +-- modem control/data channels
```

instead of relying exclusively on USB.

This is particularly relevant for:

- Quectel high-end 5G modules
- Sierra Wireless/Semtech
- Telit
- Fibocom
- high-performance Qualcomm-based designs

The important architectural consequence is that **USB should not be baked into the wwand model**.

The modem should conceptually be:

```text
                    modem
                      |
          +-----------+-----------+
          |           |           |
         USB         PCIe        UART
          |           |           |
       QMI/MBIM      MHI          AT
```

while the WWAN control plane remains independent of the physical transport.

---

# Recommended priority for wwand

I would prioritize support roughly as follows:

```text
1. QMI
   |
   +-- QMAP
   +-- RmNet
   +-- Qualcomm 4G/5G
   +-- Quectel
   +-- SIMCom
   +-- Meig

2. MBIM
   |
   +-- cdc_mbim
   +-- Sierra/Semtech
   +-- Telit
   +-- u-blox
   +-- Fibocom

3. QRTR
   |
   +-- Qualcomm 5G
   +-- PCIe/MHI
   +-- modern Qualcomm platforms

4. MHI
   |
   +-- PCIe modem transport
   +-- high-performance 5G modules

5. NCM
   |
   +-- compatibility / older devices
```

The key point is that **QMI and MBIM should both be first-class protocols**.

NCM should remain supported where useful, but it should not drive the architecture.

---

# Suggested terminology

For documentation and an OpenWrt submission, I would use:

> **wwand is a lightweight WWAN control daemon providing a unified control plane for QMI and MBIM modems, with support for Qualcomm-specific datapaths such as QMAP/RmNet and modern PCIe/MHI modem transports.**

And:

> **The architecture separates modem control protocols from the underlying datapath and physical transport, allowing the same modem abstraction to support USB, PCIe/MHI and different network interfaces.**

This describes the current modem ecosystem much better than calling wwand simply a "QMI daemon".

---

# Bottom line

The modem market does **not** justify making wwand QMI-only.

The current ecosystem is better described as:

```text
                  wwand
                    |
        +-----------+-----------+
        |                       |
       QMI                    MBIM
        |                       |
   Qualcomm                  standard
   ecosystem                 ecosystem
        |                       |
 QMAP/RmNet                  cdc_mbim
        |                       |
 USB / PCIe                 USB / PCIe
        |
       MHI
```

For an OpenWrt upstream submission, supporting **QMI + MBIM as first-class control protocols**, while keeping **QMAP/RmNet and MHI as independent datapath/transport capabilities**, gives wwand a much stronger long-term architecture than a QMI-centric design.