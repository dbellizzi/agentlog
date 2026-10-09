#!/bin/sh
# Muse runs each hook from its own file (it refuses one file for several hooks).
exec "${MUSE_PLUGIN_ROOT:-$(dirname "$0")/../..}/bin/agentlog" hook muse
