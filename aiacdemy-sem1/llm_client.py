from google import genai
from google.genai import types
from config import GEMINI_API_KEY, MODEL_NAME

class LLMClient:

    def __init__(self):
        self.client = genai.Client(
            api_key=GEMINI_API_KEY
        )

    def ask(self, prompt: str):

        for chunk in self.client.models.generate_content_stream(
            model=MODEL_NAME,
            contents=prompt,
            config=types.GenerateContentConfig(
                thinking_config=types.ThinkingConfig(thinking_budget=0)
            )
        ):
            if chunk.text:
                yield chunk.text