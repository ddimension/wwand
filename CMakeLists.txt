# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 André Valentin <avalentin@marcant.net>
#
# wwand top-level build: the native wwand_io ucode extension (io/) plus,
# by default, precompilation of the ucode tree to bytecode — one compiler
# invocation per source file, exactly like a C translation unit.
#
# How the ucode compile works (and why it needs no ordering):
#   Every intra-tree module name is passed to the compiler as `dynlink=...`
#   alongside the native extensions, so imports are never resolved at compile
#   time — each file compiles independently and the VM resolves the imports at
#   runtime through its library search path (/usr/share/ucode on the device).
#   Two invariants follow, both enforced below at configure time:
#     * imports must be namespaced (`wwand.codec.tlv`) — a relative
#       `./codec/tlv.uc` import would make the compiler statically inline a
#       second copy of the module (duplicated module state, silent);
#     * module path components must not contain `-` (the dotted runtime
#       resolver cannot map hyphens).
#   A typo'd intra-tree import is still a hard compile error: only the names
#   listed here become dynlink, anything else the compiler tries to resolve.
#   `-s` (strip debug info) is required for relocatable bytecode — unstripped
#   output embeds the absolute build path. Cost: runtime tracebacks show
#   bytecode offsets, not source lines (build with -DUCODE_PRECOMPILE=OFF and
#   ship the sources for development).
#
#   The compiling ucode binary MUST be the same ucode revision as the runtime
#   that loads the result (bytecode is VM-locked). The OpenWrt package build
#   passes the SDK host ucode via -DUCODE_COMPILER=.

cmake_minimum_required(VERSION 3.13)

project(wwand C)

add_subdirectory(io)

option(UCODE_PRECOMPILE "Precompile the ucode tree to bytecode" ON)

if(NOT UCODE_PRECOMPILE)
  return()
endif()

find_program(UCODE_COMPILER ucode DOC "ucode interpreter used as bytecode compiler")
if(NOT UCODE_COMPILER)
  message(FATAL_ERROR "ucode compiler not found (pass -DUCODE_COMPILER=/path/to/ucode)")
endif()

set(UCODE_SRC ${CMAKE_CURRENT_SOURCE_DIR}/src-ucode)
set(UCODE_OUT ${CMAKE_BINARY_DIR}/ucode/wwand)

# --- explicit source lists (deliberately no file globbing for build inputs;
# --- a verification check below fails the configure if a file on disk is
# --- missing here, so the lists cannot silently drift) ------------------------

# ES modules (top-level `export`) -> compiled with -cmodule
set(WWAND_UCODE_MODULES
  apndb.uc atcmd_parse.uc atcmd.uc backend.uc board.uc callend.uc client.uc
  codec/arfcn_bands.uc codec/hex.uc codec/mbim.uc codec/qmux.uc codec/tlv.uc
  codec/mbim_schema/basic_connect.uc codec/mbim_schema/compal.uc
  codec/mbim_schema/fibocom.uc codec/mbim_schema/ms_basic_connect_ext.uc
  codec/mbim_schema/qmi_passthrough.uc codec/mbim_schema/quectel.uc
  codec/schema/ctl.uc codec/schema/dms.uc codec/schema/dsd.uc
  codec/schema/loc.uc codec/schema/merge.uc codec/schema/nas.uc
  codec/schema/rat.uc codec/schema/uim.uc codec/schema/wda.uc
  codec/schema/wds.uc codec/schema/wms.uc
  config_check.uc config.uc context_common.uc context_mbim.uc
  context_monitor_qmi.uc context_ncm.uc context.uc ctx_settings.uc daemon.uc
  datapath_qmi.uc discovery.uc hwops.uc log.uc mbim_backend.uc mbim_client.uc
  modem_common.uc modem_init_qmi.uc modem_mbim.uc modem_ncm.uc modem_quirks.uc
  modem.uc modeswitch.uc ncm_vendors.uc netlink.uc netsel_ops.uc
  protocol_switch.uc qmi_backend.uc qmi_over_mbim.uc reconnect.uc recovery.uc
  regdetail.uc simops.uc sim_plmn.uc sim.uc sms_pdu.uc sms.uc
  telemetry_mbim.uc telemetry_ncm.uc telemetry_qmi.uc transport.uc ubus.uc
)

# executable scripts (shebang) -> compiled with -c, interpreter line preserved
set(WWAND_UCODE_PROGRAMS
  main.uc wwandctl.uc
)

# require()-loaded CommonJS shims (top-level `return`, no export): shipped as
# source — require() parses source at runtime and nothing `import`s them; they
# may freely import the bytecode modules above.
set(WWAND_UCODE_PLAIN
  atport.uc esim.uc esim_bridge.uc mbim_lazy.uc ncm_lazy.uc qmi_lazy.uc
  codec/schema/loc_lazy.uc codec/schema/wms_lazy.uc
)

# native/extern extensions resolved at runtime
set(WWAND_UCODE_EXTERN fs struct ubus uci uloop wwand_io)

# --- verification (configure-time): list completeness + import invariants ----

# the ONLY glob here, used to verify the explicit lists against the tree, never
# as a build input — a new .uc file that is not listed fails the configure.
file(GLOB_RECURSE _uc_on_disk RELATIVE ${UCODE_SRC} ${UCODE_SRC}/*.uc)
set(_uc_listed ${WWAND_UCODE_MODULES} ${WWAND_UCODE_PROGRAMS} ${WWAND_UCODE_PLAIN})
foreach(f IN LISTS _uc_on_disk)
  if(NOT f IN_LIST _uc_listed)
    message(FATAL_ERROR "src-ucode/${f} is not listed in CMakeLists.txt "
      "(add it to WWAND_UCODE_MODULES/_PROGRAMS/_PLAIN)")
  endif()
endforeach()
foreach(f IN LISTS _uc_listed)
  if(NOT f IN_LIST _uc_on_disk)
    message(FATAL_ERROR "CMakeLists.txt lists src-ucode/${f} which does not exist")
  endif()
  if(f MATCHES "-")
    message(FATAL_ERROR "src-ucode/${f}: '-' in a module path cannot be "
      "resolved by the dotted bytecode module loader — use '_'")
  endif()
  file(READ ${UCODE_SRC}/${f} _uc_body)
  if(_uc_body MATCHES "from[ \t]+'[.][.]?/")
    message(FATAL_ERROR "src-ucode/${f} uses a relative import — bytecode "
      "modules resolve only via the search path; use 'wwand.<path>' imports")
  endif()
endforeach()
unset(_uc_body)

# --- compile flags -----------------------------------------------------------

set(_dyn "")
foreach(e IN LISTS WWAND_UCODE_EXTERN)
  list(APPEND _dyn "dynlink=${e}")
endforeach()
foreach(f IN LISTS WWAND_UCODE_MODULES)
  string(REGEX REPLACE "\\.uc$" "" _name ${f})
  string(REPLACE "/" "." _name ${_name})
  list(APPEND _dyn "dynlink=wwand.${_name}")
endforeach()
list(JOIN _dyn "," _dynflags)

# --- per-file rules (independent, parallel, incremental) ---------------------

set(_uc_outputs "")
foreach(f IN LISTS WWAND_UCODE_MODULES WWAND_UCODE_PROGRAMS)
  if(f IN_LIST WWAND_UCODE_MODULES)
    set(_cflag "-cmodule,${_dynflags}")
  else()
    set(_cflag "-c${_dynflags}")
  endif()
  get_filename_component(_dir ${UCODE_OUT}/${f} DIRECTORY)
  add_custom_command(OUTPUT ${UCODE_OUT}/${f}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
    COMMAND ${UCODE_COMPILER} -s ${_cflag} -o ${UCODE_OUT}/${f} ${UCODE_SRC}/${f}
    DEPENDS ${UCODE_SRC}/${f}
    COMMENT "UC ${f}"
    VERBATIM)
  list(APPEND _uc_outputs ${UCODE_OUT}/${f})
endforeach()

foreach(f IN LISTS WWAND_UCODE_PLAIN)
  get_filename_component(_dir ${UCODE_OUT}/${f} DIRECTORY)
  add_custom_command(OUTPUT ${UCODE_OUT}/${f}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
    COMMAND ${CMAKE_COMMAND} -E copy ${UCODE_SRC}/${f} ${UCODE_OUT}/${f}
    DEPENDS ${UCODE_SRC}/${f}
    COMMENT "CP ${f}"
    VERBATIM)
  list(APPEND _uc_outputs ${UCODE_OUT}/${f})
endforeach()

add_custom_target(wwand_ucode ALL DEPENDS ${_uc_outputs})
