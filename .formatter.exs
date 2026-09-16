# Used by "mix format"
[
  import_deps: [:ash, :spark],
  plugins: [Spark.Formatter],
  inputs: ["{mix,.formatter,.credo}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
