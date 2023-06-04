defmodule Commanded.Middleware.Uniqueness do
  @behaviour Commanded.Middleware

  @moduledoc """
  Documentation for Commanded.Middleware.Uniqueness.


  """

  @default_partition __MODULE__

  defprotocol UniqueFields do
    @fallback_to_any true
    @doc """
    Returns unique fields for a command as a list of tuples as:
    `{field_name :: atom() | list(atom), error_message :: String.t(), owner :: term, opts :: keyword()}`,
    where `opts` might contain none, one or multiple options:
    `ignore_case: true` or `ignore_case: [:email, :username]` for multi-fields entities - binary-based
    fields are downcased before comparison
    `:label` - use this atom as error label
    `:is_unique` - `(term, String.t(), term, keyword() -> boolean())`
    `:partition` - use to set custom partition name
    `:no_owner` - if true then ignore owner and check `field_name` - `field_value` pair uniqueness
    in a `partition` scope. `release_by_value/3` must be used to release key-value pair in such case.

    `:no_owner` option has sense when it is necessary to ensure uniquenesses in embedded structs.
    """
    def unique(command)
  end

  defimpl UniqueFields, for: Any do
    def unique(_command), do: []
  end

  @doc """
  Returns default parition which is by default @Commanded.Middleware.Uniqueness
  """
  def default_partition do
    @default_partition
  end

  @doc """
  Claims a `key`, `value`, `owner`, `partition` set
  or reports that this combination has already been claimed.

  If a `key`, `value`, `owner`, `partition` set has to be claimed
  and an old value for the given owner exists it releases first.

  If `partition` is ommited then default partition used.
  """
  @spec claim(key :: term, value :: term, owner :: term, partition :: term) ::
          :ok
          | {:error, :already_exists}
          | {:error, :unknown_error}
          | {:error, :no_adapter}
  def claim(key, value, owner, partition \\ @default_partition) do
    case get_adapter() do
      nil -> {:error, :no_adapter}
      adapter -> adapter.claim(key, value, owner, partition)
    end
  end

  @doc """
  Claims a `key`, `value`, `partition` set
  or reports that this combination has already been claimed.

  If `partition` is ommited then default partition used.
  """
  @spec claim_without_owner(key :: term, value :: term, partition :: term) ::
          :ok
          | {:error, :already_exists}
          | {:error, :unknown_error}
          | {:error, :no_adapter}
  def claim_without_owner(key, value, partition \\ @default_partition) do
    case get_adapter() do
      nil -> {:error, :no_adapter}
      adapter -> adapter.claim(key, value, partition)
    end
  end

  @doc """
  Releases a value record via `key`, `value`, `owner`, `partition` set
  """
  @spec release(key :: term, value :: term, owner :: term, partition :: term) ::
          :ok
          | {:error, :claimed_by_another_owner}
          | {:error, :unknown_error}
          | {:error, :no_adapter}
  def release(key, value, owner, partition \\ @default_partition) do
    case get_adapter() do
      nil -> {:error, :no_adapter}
      adapter -> adapter.release(key, value, owner, partition)
    end
  end

  @doc """
  Releases a value record via `key`, `owner`, `partition` set
  """
  @spec release_by_owner(key :: term, owner :: term, partition :: term) ::
          :ok
          | {:error, :unknown_error}
          | {:error, :no_adapter}
  def release_by_owner(key, owner, partition \\ @default_partition) do
    case get_adapter() do
      nil -> {:error, :no_adapter}
      adapter -> adapter.release_by_owner(key, owner, partition)
    end
  end

  @doc """
  Releases a value record via `key`, `value`, `partition` set
  """
  @spec release_by_value(key :: term, value :: term, partition :: term) ::
          :ok
          | {:error, :unknown_error}
          | {:error, :no_adapter}
  def release_by_value(key, value, partition \\ @default_partition) do
    case get_adapter() do
      nil -> {:error, :no_adapter}
      adapter -> adapter.release_by_value(key, value, partition)
    end
  end

  ### Pipeline itself

  alias Commanded.Middleware.Pipeline

  import Pipeline

  @doc false
  def before_dispatch(%Pipeline{command: command} = pipeline) do
    case ensure_uniqueness(command) do
      :ok ->
        pipeline

      {:error, errors} ->
        pipeline
        |> respond({:error, :validation_failure, errors})
        |> halt()
    end
  end

  @doc false
  def after_dispatch(pipeline), do: pipeline

  @doc false
  def after_failure(pipeline), do: pipeline

  defp ensure_uniqueness(command) do
    ensure_uniqueness(command, get_adapter())
  end

  defp ensure_uniqueness(_command, nil) do
    require Logger
    Logger.debug("#{__MODULE__}: No unique cache adapter defined in config! Assume the value is unique.")

    :ok
  end

  defp ensure_uniqueness(command, adapter) do
    command
    |> UniqueFields.unique()
    |> ensure_uniqueness(command, adapter, [], [])
  end

  defp ensure_uniqueness([record | rest], command, adapter, errors, to_release) do
    {_, error_message, _, _} = record = expand_record(record)
    label = get_label(record)

    {errors, to_release} =
      case claim_value(record, command, adapter) do
        {key, value, owner, partition} ->
          to_release = [{key, value, owner, partition} | to_release]

          {errors, to_release}

        _ ->
          errors = [{label, error_message} | errors]

          {errors, to_release}
      end

    ensure_uniqueness(rest, command, adapter, errors, to_release)
  end

  defp ensure_uniqueness([], _command, _adapter, [], _to_release), do: :ok
  defp ensure_uniqueness([], _command, _adapter, errors, []), do: {:error, errors}

  defp ensure_uniqueness([], command, adapter, errors, to_release) do
    Enum.each(to_release, &release(&1, adapter))

    ensure_uniqueness([], command, adapter, errors, [])
  end

  defp claim_value({fields, _, owner, opts}, command, adapter)
       when is_list(fields) do
    value =
      fields
      |> Enum.reduce([], fn field_name, acc ->
        ignore_case = Keyword.get(opts, :ignore_case)

        [get_field_value(command, field_name, ignore_case) | acc]
      end)

    key = Module.concat(fields)
    command = %{key => value}
    entity = {key, "", owner, opts}
    claim_value(entity, command, adapter)
  end

  defp claim_value({field_name, _, owner, opts}, command, adapter)
       when is_atom(field_name) do
    ignore_case = Keyword.get(opts, :ignore_case)
    value = get_field_value(command, field_name, ignore_case)
    partition = get_partition(opts, command)

    require Logger

    claim_result =
      case Keyword.get(opts, :no_owner, false) do
        false ->
          adapter.claim(field_name, value, owner, partition)

        true ->
          adapter.claim(field_name, value, partition)

        _ ->
          raise ArgumentError,
                "Commanded.Middleware.Uniqueness.UniqueFields :no_owner option can only be either true or false"
      end

    case claim_result do
      :ok ->
        case external_check(field_name, value, owner, command, opts) do
          true ->
            {field_name, value, owner, partition}

          _ ->
            release({field_name, value, owner, partition}, adapter)
            {:error, :external_check_failed}
        end

      error ->
        error
    end
  end

  defp release({key, value, owner, partition}, adapter),
    do: adapter.release(key, value, owner, partition)

  defp external_check(field_name, value, owner, command, opts) when is_list(opts),
    do: external_check(field_name, value, owner, command, get_external_checker(opts))

  defp external_check(field_name, value, owner, _command, {checker, opts})
       when is_function(checker, 4),
       do: checker.(field_name, value, owner, opts)

  defp external_check(_field_name, _value, _owner, _command, {nil, _}), do: true

  defp external_check(_field_name, _value, _owner, %{__struct__: module}, _opts),
    do:
      raise(
        "#{__MODULE__}: The ':is_unique' option for the #{module} command has incorrect value. It should be only a function with 4 arguments"
      )

  defp expand_record({one, two, three}), do: {one, two, three, []}
  defp expand_record(entity), do: entity

  defp get_field_value(command, field_name, ignore_case)

  defp get_field_value(command, field_name, ignore_case) when is_list(ignore_case),
    do: get_field_value(command, field_name, Enum.any?(ignore_case, &(&1 == field_name)))

  defp get_field_value(command, field_name, field_name),
    do: get_field_value(command, field_name, true)

  defp get_field_value(command, field_name, true),
    do: command |> get_field_value(field_name, false) |> downcase()

  defp get_field_value(command, field_name, _), do: Map.get(command, field_name)

  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(value), do: value

  defp get_label({entity, _, _, opts}), do: Keyword.get(opts, :label, entity)

  defp get_external_checker(opts), do: {Keyword.get(opts, :is_unique), opts}

  defp get_partition(opts, command), do: get_partition(opts, command, use_command_as_partition?())

  defp get_partition(opts, %command{}, true), do: Keyword.get(opts, :partition, command)
  defp get_partition(opts, _, _), do: Keyword.get(opts, :partition, default_partition())

  defp get_adapter, do: Application.get_env(:commanded_uniqueness_middleware, :adapter)

  defp use_command_as_partition?,
    do: Application.get_env(:commanded_uniqueness_middleware, :use_command_as_partition)
end
