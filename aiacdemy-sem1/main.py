from llm_client import LLMClient

def main():

    llm = LLMClient()

    print("LLM Assistant")
    print("Type 'exit' to quit")

    while True:

        question = input("\nYou: ")

        if question.lower() == "exit":
            break

        print("\nAssistant:")
        for chunk in llm.ask(question):
            print(chunk, end="", flush=True)
        print()

if __name__ == "__main__":
    main()