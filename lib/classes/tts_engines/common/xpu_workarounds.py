import os
import torch
import torch.nn as nn

def patch_coqui_hifigan_for_xpu(engine):
    """
    Universal scanner that finds any Coqui HiFi-GAN generator in the engine 
    (XTTS, VITS, YourTTS, or external vocoders) and moves it to CPU to 
    bypass the oneDNN JIT dilated-conv bug on Intel XPU.
    """
    if os.environ.get("E2A_XPU_HIFIGAN_CPU", "1") != "1":
        return engine
    if not hasattr(torch, 'xpu') or not torch.xpu.is_available():
        return engine

    print("[XPU Workaround] Scanning engine for HiFi-GAN vocoders...")
    patched_count = 0

    def _patch_module(module):
        nonlocal patched_count
        if getattr(module, '_xpu_cpu_patched', False):
            return
        
        # Coqui's HifiganGenerator signature: has 'resblocks' and 'ups'
        if hasattr(module, 'resblocks') and hasattr(module, 'ups'):
            print(f"[XPU Workaround] Found HiFi-GAN module ({module.__class__.__name__}). Moving to CPU.")
            original_forward = module.forward
            
            def cpu_forward(*args, **kwargs):
                # Detect target device from first tensor argument
                target_device = None
                for a in args:
                    if isinstance(a, torch.Tensor):
                        target_device = a.device
                        break
                
                # Move inputs to CPU
                cpu_args = [a.cpu() if isinstance(a, torch.Tensor) else a for a in args]
                cpu_kwargs = {k: v.cpu() if isinstance(v, torch.Tensor) else v for k, v in kwargs.items()}
                
                # Run on CPU
                result = original_forward(*cpu_args, **cpu_kwargs)
                
                # Move result back to original device
                if target_device is not None:
                    if isinstance(result, torch.Tensor):
                        return result.to(target_device)
                    elif isinstance(result, tuple):
                        return tuple(r.to(target_device) if isinstance(r, torch.Tensor) else r for r in result)
                return result

            module.forward = cpu_forward
            module.cpu() # Move weights to CPU
            module._xpu_cpu_patched = True
            patched_count += 1

    # 1. Walk the engine itself (covers XTTS, VITS loaded directly)
    if isinstance(engine, nn.Module):
        for _, module in engine.named_modules():
            _patch_module(module)
            
    # 2. Walk the synthesizer (covers TTS API: VITS, YourTTS, Tacotron2, GlowTTS)
    syn = getattr(engine, 'synthesizer', None)
    if syn is not None:
        if isinstance(syn, nn.Module):
            for _, module in syn.named_modules():
                _patch_module(module)
        # Check vocoder_model directly if not an nn.Module
        vocoder = getattr(syn, 'vocoder_model', None)
        if vocoder is not None and isinstance(vocoder, nn.Module):
            for _, module in vocoder.named_modules():
                _patch_module(module)

    if patched_count > 0:
        print(f"[XPU Workaround] Successfully patched {patched_count} HiFi-GAN module(s) to run on CPU.")
    else:
        print("[XPU Workaround] No patchable HiFi-GAN modules found.")
        
    return engine