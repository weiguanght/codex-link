"""Compatibility for verified desktop IPC revisions, outside the vendor copy."""
import logging

from bridge.service import Bridge

LOG = logging.getLogger(__name__)
STREAM_VERSIONS = (11, 13)


class DesktopBridge(Bridge):
    def _event(self, message):
        if message.get('method') == 'thread-stream-state-changed':
            version = message.get('version')
            if version not in STREAM_VERSIONS:
                LOG.warning('Unsupported desktop stream version %r; supported versions: %s',
                            version, STREAM_VERSIONS)
            elif version == 13:
                # Verified against desktop 26.1111.21308: snapshot, canonical
                # turnHistory and revisioned patches retain the v11 envelope.
                # Only adapt the upstream version gate; preserve its owner,
                # host, revision and patch validation, and all write versions.
                message = dict(message, version=11)
        return super()._event(message)
