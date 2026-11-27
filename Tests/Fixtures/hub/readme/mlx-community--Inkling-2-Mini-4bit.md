---
license: apache-2.0
license_link: https://www.apache.org/licenses/LICENSE-2.0
library_name: mlx
pipeline_tag: image-text-to-text
base_model: thinkingmachines/Inkling-2-Mini
tags:
- moe
- mlx
---

# mlx-community/Inkling-2-Mini-4bit

This model [mlx-community/Inkling-2-Mini-4bit](https://huggingface.co/mlx-community/Inkling-2-Mini-4bit) was converted to MLX format from [thinkingmachines/Inkling-2-Mini](https://huggingface.co/thinkingmachines/Inkling-2-Mini) using mlx-lm with [ml-explore/mlx-lm#2086](https://github.com/ml-explore/mlx-lm/pull/2086). Refer to the [original model card](https://huggingface.co/thinkingmachines/Inkling-2-Mini) for more details on the model.

It takes text and image input. The vision tower is included. The DSpark draft is not included.

The routed experts keep the original quantization. They are NVFP4 with a per-expert global scale in layers 0 to 19 and MXFP8 in layers 20 to 23. The attention, embedding and output head weights are 4-bit affine with group size 64. The vision tower stays in bfloat16, the router in float32, and the loop message gates are not quantized.

Tested with the branch of that pull request.

## Use with mlx

```bash
pip install -U git+https://github.com/ml-explore/mlx-lm.git@refs/pull/2086/head
```

```python
from mlx_lm import load, generate

model, tokenizer = load("mlx-community/Inkling-2-Mini-4bit")

prompt = "hello"

if tokenizer.chat_template is not None:
    messages = [{"role": "user", "content": prompt}]
    prompt = tokenizer.apply_chat_template(
        messages, add_generation_prompt=True, return_dict=False,
    )

response = generate(model, tokenizer, prompt=prompt, verbose=True)
```

For image input, run `mlx_lm.server` and send the images as `image_url` parts of a chat message.
