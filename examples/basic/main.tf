# Minimal end-to-end example for the sample resource. After renaming your
# provider (Initialize-Fork.ps1), update the provider name here - or delete
# this example along with the samples and add your own.
terraform {
  required_providers {
    yourprovider = {
      source = "yournamespace/yourprovider"
    }
  }
}

provider "yourprovider" {
  default_directory = path.cwd
}

resource "yourprovider_example_file" "hello" {
  path    = "hello.txt"
  content = "Hello from a template-built provider!"
}

data "yourprovider_example_file" "readback" {
  path       = "hello.txt"
  depends_on = [yourprovider_example_file.hello]
}

output "file_id" {
  value = yourprovider_example_file.hello.id
}

output "content_read_back" {
  value = data.yourprovider_example_file.readback.content
}
