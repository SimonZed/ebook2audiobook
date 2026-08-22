# lib/classes/tts_engines/common/xpu_workarounds.py
import os
import torch

def move_hifigan_to_cpu(engine):
    """
    Move ONLY the HiFi-GAN waveform_decoder to CPU to bypass oneDNN JIT bugs 
    on Intel XPU (e.g., "could not create a primitive" in dilated convolutions).
    
    We intentionally leave the speaker_encoder on the original device to avoid 
    device mismatch errors during get_conditioning_latents().
    """
    # Allow explicit opt-out via environment variable for testing/debugging
    if os.environ.get("E2A_XPU_HIFIGAN_CPU", "1") != "1":
        return engine
        
    if not hasattr(torch, 'xpu') or not torch.xpu.is_available():
        return engine
        
    decoder = getattr(engine, "hifigan_decoder", None)
    if decoder is None:
        return engine

    # Target ONLY the waveform generator, not the speaker encoder
    waveform_decoder = getattr(decoder, "waveform_decoder", None)
    if waveform_decoder is None:
        return engine

    print("[XPU Workaround] Moving HiFi-GAN waveform_decoder to CPU to bypass oneDNN JIT bug...")
    
    original_forward = waveform_decoder.forward

    def cpu_forward(*args, **kwargs):
        # Move all tensor inputs to CPU before calling the original forward
        cpu_args = [a.cpu() if isinstance(a, torch.Tensor) else a for a in args]
        cpu_kwargs = {k: v.cpu() if isinstance(v, torch.Tensor) else v for k, v in kwargs.items()}
        return original_forward(*cpu_args, **cpu_kwargs)

    # Apply the patch and move ONLY the waveform_decoder to CPU
    waveform_decoder.forward = cpu_forward
    decoder.waveform_decoder = waveform_decoder.cpu()
    
    return engine