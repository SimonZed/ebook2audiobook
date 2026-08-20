from typing import Any
from lib.conf import devices, default_vram_flush_ratio
from lib.classes.tts_registry import TTSRegistry

class TTSManager:

    def __init__(self, session:Any)->None:
        self.session = session
        engine_name = session.get("tts_engine")
        if engine_name is None:
            raise ValueError("session['tts_engine'] is missing")
        try:
            engine_cls = TTSRegistry.ENGINES[engine_name]
        except KeyError:
            raise ValueError(
                f"Invalid tts_engine '{engine_name}'. "
                f"Expected one of: {', '.join(TTSRegistry.ENGINES)}"
            )
        self.engine = engine_cls(session)
    
    def set_voice(self, block_voice:str|None)->tuple:
        return self.engine._set_voice(block_voice)

    def convert_sentence2audio(self, sentence_file:str, sentence:str, **kwargs)->tuple:
        result = self.engine.convert(sentence_file, sentence, **kwargs)
        # Engine-agnostic seam: every engine's per-sentence work funnels through
        # here. The caching allocator only hands blocks back to the driver on an
        # explicit empty_cache(), and each sentence allocates a different shape,
        # so the reserved pool climbs monotonically and never shrinks on its own.
        # Check the device high-water mark once per sentence and flush through the
        # engine's existing cleanup_memory() when it crosses default_vram_flush_ratio.
        if default_vram_flush_ratio > 0:
            try:
                import torch
                backend = None
                if self.session['device'] == devices['XPU']['proc']:
                    backend = torch.xpu
                elif self.session['device'] in (devices['CUDA']['proc'], devices['ROCM']['proc'], devices['JETSON']['proc']):
                    backend = torch.cuda
                if backend is not None:
                    if hasattr(backend, 'mem_get_info'):
                        # driver-level truth: counts the oneDNN/SYCL kernel binaries
                        # and scratchpads too, not only what torch itself allocated
                        free_bytes, total_bytes = backend.mem_get_info()
                        used_bytes = total_bytes - free_bytes
                    else:
                        total_bytes = backend.get_device_properties(0).total_memory
                        used_bytes = backend.memory_reserved()
                    used_ratio = used_bytes / total_bytes if total_bytes > 0 else 0.0
                    if used_ratio >= default_vram_flush_ratio:
                        msg = f"convert_sentence2audio() {self.session['device']} at {used_ratio * 100:.1f}% of {total_bytes / 1024 ** 3:.2f}GB, flushing device cache…"
                        print(msg)
                        self.engine.cleanup_memory()
            except Exception:
                # a memory probe must never be the thing that kills a conversion
                pass
        return result