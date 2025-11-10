import requests
from typing import List, Optional

def inference_up(
   base_url: str,
   model: str,
   config: dict
) -> dict:
   url = f"{base_url}/api/v1/inference/up"
   payload = {
       "model": model,
       "dtype": "float16",
       "additional_args": config["args"]
   }

   response = requests.post(url, json=payload)
   response.raise_for_status()

   return response.json()

model_name = "Qwen/Qwen3-235B-A22B-Instruct-2507-FP8"
model_config = {
   "args": [
       "--tensor-parallel-size", "4",
   ]
}

inference_up(
   base_url="http://localhost:8080/",
   model=model_name,
   config=model_config
)