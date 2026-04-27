# Backend/server/face_recognition_utils.py
"""
Face recognition using facenet-pytorch (MTCNN + InceptionResnetV1).

Replaces the dlib-based `face_recognition` library entirely:
  - No cmake / g++ / libopenblas / liblapack needed in Docker
  - Models use PyTorch (already a project dependency)
  - InceptionResnetV1 (VGGFace2) produces 512-d embeddings; more accurate
    than dlib's 128-d HOG model
  - Comparison uses cosine distance instead of Euclidean distance
    → tolerance default changed from 0.6 (Euclidean) to 0.4 (cosine)
      Lower cosine distance = more similar faces.
      Tune this value: 0.3 = very strict, 0.5 = lenient.

Drop-in compatible: encode_face, compare_faces, hash_encoding,
encrypt_encoding, decrypt_encoding — same signatures as before.
"""

import io
import base64
import logging
import hashlib
from typing import Optional, Tuple

import numpy as np
from PIL import Image, ImageOps
from fastapi.concurrency import run_in_threadpool

logger = logging.getLogger(__name__)


class FaceRecognitionManager:
    """
    Face recognition using facenet-pytorch.
    Thread-safe: MTCNN and InceptionResnetV1 are loaded once at startup
    and reused. All torch operations run on CPU.
    """

    def __init__(self):
        try:
            import torch
            from facenet_pytorch import MTCNN, InceptionResnetV1

            self._torch = torch
            device = torch.device("cpu")

            # MTCNN: face detection + alignment → crops face to 160×160
            self._mtcnn = MTCNN(
                image_size=160,
                margin=10,          # small margin around detected face
                min_face_size=40,   # ignore tiny faces (< 40 px)
                thresholds=[0.6, 0.7, 0.7],  # P-net, R-net, O-net thresholds
                keep_all=False,     # return the single highest-probability face
                device=device,
            )

            # InceptionResnetV1: produces a 512-d L2-normalised embedding
            self._resnet = (
                InceptionResnetV1(pretrained="vggface2")
                .eval()
                .to(device)
            )

            self.enabled = True
            logger.info("✅ Face recognition enabled (facenet-pytorch / VGGFace2)")

        except ImportError as exc:
            logger.warning(
                "facenet-pytorch not installed — face matching disabled. "
                "Install with: pip install facenet-pytorch. Error: %s", exc
            )
            self.enabled = False
        except Exception as exc:
            logger.error("Face recognition init failed: %s", exc, exc_info=True)
            self.enabled = False

    # ──────────────────────────────────────────────────────────────────────────
    # Public API
    # ──────────────────────────────────────────────────────────────────────────

    def encode_face(self, image_bytes: bytes) -> Optional[np.ndarray]:
        """
        Extract a 512-d face embedding from raw image bytes.

        Returns:
            numpy array (shape [512]) or None if no face detected / error.
        """
        if not self.enabled:
            return None

        try:
            image = self._load_image(image_bytes)
            face_tensor = self._mtcnn(image)  # → Tensor[3, 160, 160] or None

            if face_tensor is None:
                logger.warning("encode_face: no face detected in image")
                return None

            with self._torch.no_grad():
                embedding = self._resnet(face_tensor.unsqueeze(0))  # [1, 512]

            return embedding.squeeze().numpy()  # [512]

        except Exception as exc:
            logger.error("encode_face failed: %s", exc, exc_info=True)
            return None

    def compare_faces(
        self,
        encoding1: np.ndarray,
        encoding2: np.ndarray,
        tolerance: float = 0.4,
    ) -> Tuple[bool, float]:
        """
        Compare two 512-d face embeddings with cosine distance.

        Args:
            encoding1, encoding2: embeddings from encode_face()
            tolerance: cosine distance threshold [0.0 – 1.0].
                       0.3 = very strict, 0.4 = recommended, 0.5 = lenient.

        Returns:
            (is_match: bool, confidence: float [0–1])
        """
        if not self.enabled:
            return False, 0.0

        try:
            # L2-normalise (InceptionResnetV1 returns normalised vectors, but be safe)
            v1 = encoding1 / (np.linalg.norm(encoding1) + 1e-10)
            v2 = encoding2 / (np.linalg.norm(encoding2) + 1e-10)

            cosine_distance = float(1.0 - np.dot(v1, v2))
            is_match = cosine_distance <= tolerance
            confidence = float(max(0.0, 1.0 - cosine_distance))
            return is_match, confidence

        except Exception as exc:
            logger.error("compare_faces failed: %s", exc)
            return False, 0.0

    def hash_encoding(self, encoding: np.ndarray) -> str:
        """SHA-256 hash of the raw embedding bytes (for privacy-preserving dedup)."""
        return hashlib.sha256(encoding.tobytes()).hexdigest()

    async def encrypt_encoding(self, encoding: np.ndarray, master_key: bytes) -> str:
        """AES-GCM encrypt a face embedding for storage."""
        import json
        from .crypto_utils import aesgcm_encrypt

        encoding_json = json.dumps(encoding.tolist()).encode("utf-8")
        encrypted = await run_in_threadpool(aesgcm_encrypt, encoding_json, master_key)
        return base64.b64encode(
            json.dumps(encrypted).encode("utf-8")
        ).decode("utf-8")

    async def decrypt_encoding(
        self, encrypted_b64: str, master_key: bytes
    ) -> Optional[np.ndarray]:
        """Decrypt and reconstruct a stored face embedding."""
        import json
        from .crypto_utils import aesgcm_decrypt

        try:
            encrypted_data = json.loads(base64.b64decode(encrypted_b64))
            decrypted_bytes = await run_in_threadpool(
                aesgcm_decrypt, encrypted_data, master_key
            )
            return np.array(json.loads(decrypted_bytes.decode("utf-8")))
        except Exception as exc:
            logger.error("decrypt_encoding failed: %s", exc)
            return None

    # ──────────────────────────────────────────────────────────────────────────
    # Internal helpers
    # ──────────────────────────────────────────────────────────────────────────

    @staticmethod
    def _load_image(image_bytes: bytes) -> Image.Image:
        """Open bytes → RGB PIL Image, correcting EXIF rotation."""
        image = Image.open(io.BytesIO(image_bytes))
        try:
            image = ImageOps.exif_transpose(image)
        except Exception:
            pass
        if image.mode != "RGB":
            image = image.convert("RGB")
        return image


# ── Global singleton ──────────────────────────────────────────────────────────
face_recognition_manager = FaceRecognitionManager()