from llm_client import LLMClient

def main():

    llm = LLMClient()

    print("LLM Assistant")
    print("Type 'exit' to quit")

    while True:

        question = input("\nYou: ")

        if question.lower() == "exit":
            break

        answer = llm.ask(question)

        print("\nAssistant:")
        print(answer)

if __name__ == "__main__":
    main()