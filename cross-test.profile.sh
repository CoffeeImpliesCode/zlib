# cross-test profile; settings only.
# Leave target selection to the harness's active matrix.
# Use the standard Zig test step; executor selection stays with the harness.

CROSS_BUILD_STEP=test
CROSS_BUILD_JOBS=4
CROSS_BUILD_TIMEOUT=3600
CROSS_TIMEOUT=1800
