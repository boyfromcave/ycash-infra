variable "seed_count" {
  description = "How many seed hosts' addresses to allocate (seed-0 .. seed-<n-1>); each host serves every network of the stack, each on its own port. Raising it adds addresses; lowering it is refused (prevent_destroy)."
  type        = number
  default     = 2
  validation {
    condition     = var.seed_count >= 1 && var.seed_count <= 16 && floor(var.seed_count) == var.seed_count
    error_message = "seed_count must be a whole number from 1 to 16."
  }
}

variable "name_prefix" {
  description = "Prefix of the Name tag of each address (<prefix>-seed-<i>). Keep it generic."
  type        = string
  default     = "testnet-seed"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.name_prefix))
    error_message = "name_prefix: lowercase letters, digits and dashes, starting with a letter, at most 31 characters."
  }
}

variable "tags" {
  description = "Extra tags on every address. Keep them generic: no names, no account details."
  type        = map(string)
  default     = {}
}
