from typing import Any
from lib.conf import devices, default_vram_flush_ratio
from lib.classes.tts_registry import TTSRegistry

class TTSManager:

    def __init__(self, session:Any)->None:
        self.session = session
        # watermark state: last 5% band reported, plus a one-shot flag so a broken
        # memory probe says so once instead of silently doing nothing forever
        self.vram_band = -1
        self.vram_probe_off = False
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
        # Engine-agnostic seam: every engine's per-sentence work funnels through here.
        # Checked BEFORE the engine call, so a flush creates headroom for the sentence
        # about to be synthesised — checking afterwards leaves the sentence that trips
        # the limit running with none. Reports every 5% band so growth is visible in
        # the log even when the limit is never reached, and reports usage again after
        # a flush so it is obvious whether the flush reclaimed anything at all
        # (empty_cache() returns allocator blocks; it cannot free oneDNN's JIT
        # primitive cache or the SYCL program cache).
        if default_vram_flush_ratio > 0 and not self.vram_probe_off:
            try:
                import torch
                backend = None
                if self.session['device'] == devices['XPU']['proc']:
                    backend = torch.xpu
                elif self.session['device'] in (devices['CUDA']['proc'], devices['ROCM']['proc'], devices['JETSON']['proc']):
                    backend = torch.cuda
                if backend is None:
                    self.vram_probe_off = True
                else:
                    if hasattr(backend, 'mem_get_info'):
                        # driver-level truth: counts the oneDNN/SYCL kernel binaries
                        # and scratchpads too, not only what torch itself allocated
                        free_bytes, total_bytes = backend.mem_get_info()
                        used_bytes = total_bytes - free_bytes
                    else:
                        total_bytes = backend.get_device_properties(0).total_memory
                        used_bytes = backend.memory_reserved()
                    used_ratio = used_bytes / total_bytes if total_bytes > 0 else 0.0
                    band = int(used_ratio * 20)
                    if band != self.vram_band:
                        self.vram_band = band
                        msg = f"{self.session['device']} memory at {used_ratio * 100:.1f}% of {total_bytes / 1024 ** 3:.2f}GB"
                        print(msg)
                    if used_ratio >= default_vram_flush_ratio:
                        self.engine.cleanup_memory()
                        if hasattr(backend, 'mem_get_info'):
                            free_bytes, total_bytes = backend.mem_get_info()
                            msg = f"flushed device cache, now at {(total_bytes - free_bytes) / total_bytes * 100:.1f}%"
                            print(msg)
            except Exception as e:
                self.vram_probe_off = True
                error = f'convert_sentence2audio() memory watermark disabled: {e!r}'
                print(error)
        return self.engine.convert(sentence_file, sentence, **kwargs)