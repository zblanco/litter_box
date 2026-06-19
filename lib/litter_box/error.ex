defmodule LitterBox.Error do
  @moduledoc """
  Normalized error payload for public LitterBox boundaries.
  """

  @enforce_keys [:kind, :message]
  defstruct [:kind, :message, details: %{}, source: nil, retryable?: false, metadata: %{}]

  @type kind :: :validation | :provider | :timeout | :unexpected | atom()

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          details: map(),
          source: atom() | module() | nil,
          retryable?: boolean(),
          metadata: map()
        }

  @spec new(kind(), String.t(), keyword()) :: t()
  def new(kind, message, opts \\ [])
      when is_atom(kind) and is_binary(message) and is_list(opts) do
    %__MODULE__{
      kind: kind,
      message: message,
      details: Keyword.get(opts, :details, %{}),
      source: Keyword.get(opts, :source),
      retryable?: Keyword.get(opts, :retryable?, false),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec validation(String.t(), keyword()) :: t()
  def validation(message, opts \\ []), do: new(:validation, message, opts)

  @spec provider(String.t(), keyword()) :: t()
  def provider(message, opts \\ []), do: new(:provider, message, opts)

  @spec timeout(String.t(), keyword()) :: t()
  def timeout(message, opts \\ []), do: new(:timeout, message, opts)

  @spec unexpected(String.t(), keyword()) :: t()
  def unexpected(message, opts \\ []), do: new(:unexpected, message, opts)

  @spec from_reason(term(), keyword()) :: t()
  def from_reason(reason, opts \\ []) do
    kind = Keyword.get(opts, :kind, :unexpected)
    message = Keyword.get(opts, :message, inspect(reason))

    new(kind, message,
      details: Map.put(Keyword.get(opts, :details, %{}), :reason, reason),
      source: Keyword.get(opts, :source),
      retryable?: Keyword.get(opts, :retryable?, false),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec from_exception(Exception.t(), keyword()) :: t()
  def from_exception(exception, opts \\ []) do
    from_reason(exception,
      kind: Keyword.get(opts, :kind, :unexpected),
      message: Exception.message(exception),
      details: Keyword.get(opts, :details, %{}),
      source: Keyword.get(opts, :source),
      retryable?: Keyword.get(opts, :retryable?, false),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end
end
