# lib/classes/tts_engines/common/xpu_workarounds.py
import os
import torch

def move_hifigan_to_cpu(engine):
    """
    Move a HiFi-GAN vocoder to CPU to bypass oneDNN JIT compilation bugs 
    on Intel XPU (e.g., "could not create a primitive" in dilated convolutions).
    
    Safe to call on any engine: it's a no-op if no hifigan_decoder is present
    or if XPU is not available.
    """
    # Allow explicit opt-out via environment variable for testing/debugging
    if os.environ.get("E2A_XPU_HIFIGAN_CPU", "1") != "1":
        return engine
        
    if not hasattr(torch, 'xpu') or not torch.xpu.is_available():
        return engine
        
    decoder = getattr(engine, "hifigan_decoder", None)
    if decoder is None:
        return engine

    print("[XPU Workaround] Moving HiFi-GAN vocoder to CPU to bypass oneDNN JIT bug...")
    
    # Keep a reference to the original forward pass
    original_forward = decoder.forward

    def cpu_forward(*args, **kwargs):
        # Move all tensor inputs to CPU before calling the original forward
        cpu_args = [a.cpu() if isinstance(a, torch.Tensor) else a for a in args]
        cpu_kwargs = {k: v.cpu() if isinstance(v, torch.Tensor) else v for k, v in kwargs.items()}
        return original_forward(*cpu_args, **cpu_kwargs)

    # Apply the patch and move the module to CPU
    decoder.forward = cpu_forward
    engine.hifigan_decoder = decoder.cpu()
    
    return engine