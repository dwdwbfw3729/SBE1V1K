# Sourced after the component's historical source lock. build.sh records the
# selected image's actual ID; every compiler launch still checks that identity.
if [ -n "${SBE_BUILDER_IMAGE:-}" ]; then
    : "${SBE_BUILDER_IMAGE_ID:?builder identity is required with SBE_BUILDER_IMAGE}"
    BUILDER_IMAGE_REF=$SBE_BUILDER_IMAGE
    BUILDER_IMAGE_ID=$SBE_BUILDER_IMAGE_ID
    UBUS_BUILDER_IMAGE_REF=$SBE_BUILDER_IMAGE
    UBUS_BUILDER_IMAGE_ID=$SBE_BUILDER_IMAGE_ID
fi
