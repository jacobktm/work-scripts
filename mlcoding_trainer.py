#!/bin/python3

import os
from pathlib import Path
from transformers import GPT2Tokenizer, GPT2LMHeadModel, TextDataset, DataCollatorForLanguageModeling
from transformers import Trainer, TrainingArguments
import torch

os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "max_split_size_mb:50"

# Set the memory limit (in bytes)
#MEMORY_LIMIT = 7 * 1024 * 1024 * 1024  # 7 GB
#torch.cuda.reset_max_memory_allocated(MEMORY_LIMIT)

# Function to load code samples in chunks
def load_code_samples(root_dir, extensions, chunk_size):
    code_samples = []
    current_size = 0

    for ext in extensions:
        for code_file_path in Path(root_dir).rglob(f'*.{ext}'):
            if not code_file_path.is_dir():
                file_size = os.path.getsize(code_file_path)

                if current_size + file_size > chunk_size:
                    yield code_samples
                    code_samples = []
                    current_size = 0

                with open(code_file_path, 'r', encoding='utf-8', errors='ignore') as code_file:
                    code_text = code_file.read()
                    code_samples.append(code_text)
                    current_size += file_size

    if code_samples:
        yield code_samples


def create_dataset(tokenizer, file_path, max_length):
    dataset = TextDataset(
        tokenizer=tokenizer,
        file_path=file_path,
        block_size=max_length,
        overwrite_cache=True
    )
    return dataset


# Parameters
ROOT_DIR = "/home/system76/mlcoding/training"
CHUNK_SIZE = 512 * 1024 * 1024  # 100 MB, for example
MAX_LENGTH = 1024
MODEL_NAME = "gpt2"

# Set up the tokenizer and model
my_tokenizer = GPT2Tokenizer.from_pretrained(MODEL_NAME)
my_model = GPT2LMHeadModel.from_pretrained(MODEL_NAME)

# Training configuration
training_args = TrainingArguments(
    output_dir="/home/system76/mlcoding",
    overwrite_output_dir=True,
    num_train_epochs=3,
    per_device_train_batch_size=1,
    gradient_accumulation_steps=1_000,
    save_steps=10_000,
    save_total_limit=2,
    fp16 = True,
)

# Set up the data collator
data_collator = DataCollatorForLanguageModeling(
    tokenizer=my_tokenizer, mlm=False
)

# Set up the Trainer
trainer = Trainer(
    model=my_model,
    args=training_args,
    data_collator=data_collator,
)

# Extensions to search for in the repositories
EXTENSIONS = ["c", "cpp", "h", "py", "rs", "js", "html", "css", "sh", "asm", "h", "hpp", "s", "S"]

# Load and train on code samples in chunks
for chunk_idx, code_samples_chunk in enumerate(load_code_samples(ROOT_DIR, EXTENSIONS, CHUNK_SIZE)):
    # Save the code samples chunk to a text file
    with open(f"source_code_samples_chunk_{chunk_idx}.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(code_samples_chunk))

    # Create the dataset for the current chunk
    dataset_chunk = create_dataset(my_tokenizer, f"source_code_samples_chunk_{chunk_idx}.txt", MAX_LENGTH)

    # Update the Trainer with the new dataset chunk
    trainer.train_dataset = dataset_chunk

    # Train the model on the current chunk
    trainer.train()

    # Save the trained model
    trainer.save_model(f"trained_model_chunk_{chunk_idx}")
