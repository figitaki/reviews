defmodule Reviews.Reviews do
  @moduledoc """
  The Reviews context: reviews, patchsets, and per-patchset files.

  This is the only module that should touch `Reviews.Repo` for these entities.
  Controllers/LiveViews go through these functions.
  """
  import Ecto.Query, warn: false

  alias Reviews.Repo
  alias Reviews.Reviews.{File, Patchset, Review}
  alias Reviews.Accounts.User

  ## Reviews

  @slug_bytes 5

  def get_review_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Review, slug: slug)
  end

  def get_review_by_slug!(slug) when is_binary(slug) do
    Repo.get_by!(Review, slug: slug)
  end

  @doc """
  Creates a review along with its initial patchset (#1) in a single transaction.

  Returns `{:ok, %{review: review, patchset: patchset, files: files}}` or
  `{:error, step, changeset, _}`.

  Populates per-file rows from the raw unified diff in the same transaction so
  the LiveView sidebar can render without re-parsing on each load.
  """
  def create_review_with_initial_patchset(%User{} = author, attrs) when is_map(attrs) do
    slug = attrs[:slug] || attrs["slug"] || generate_slug()
    raw_diff = attrs[:raw_diff] || attrs["raw_diff"]

    review_attrs = %{
      slug: slug,
      title: attrs[:title] || attrs["title"],
      description: attrs[:description] || attrs["description"],
      author_id: author.id
    }

    patchset_attrs = %{
      number: 1,
      raw_diff: raw_diff,
      packet: attrs[:packet] || attrs["packet"],
      base_sha: attrs[:base_sha] || attrs["base_sha"],
      branch_name: attrs[:branch_name] || attrs["branch_name"],
      pushed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:review, Review.changeset(%Review{}, review_attrs))
    |> Ecto.Multi.insert(:patchset, fn %{review: review} ->
      Patchset.changeset(%Patchset{}, Map.put(patchset_attrs, :review_id, review.id))
    end)
    |> Ecto.Multi.run(:files, fn _repo, %{patchset: patchset} ->
      insert_files_for_patchset(patchset, raw_diff)
    end)
    |> Repo.transaction()
  end

  ## Patchsets

  @doc """
  Appends a new patchset to an existing review. Auto-numbers to (max+1).
  Also populates the per-file rows for the new patchset so the sidebar
  renders without a re-parse.
  """
  def append_patchset(%Review{} = review, attrs) when is_map(attrs) do
    next_number = next_patchset_number(review.id)
    raw_diff = attrs[:raw_diff] || attrs["raw_diff"]

    patchset_attrs = %{
      review_id: review.id,
      number: next_number,
      raw_diff: raw_diff,
      packet: attrs[:packet] || attrs["packet"],
      base_sha: attrs[:base_sha] || attrs["base_sha"],
      branch_name: attrs[:branch_name] || attrs["branch_name"],
      pushed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:patchset, Patchset.changeset(%Patchset{}, patchset_attrs))
    |> Ecto.Multi.run(:files, fn _repo, %{patchset: patchset} ->
      insert_files_for_patchset(patchset, raw_diff)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{patchset: patchset}} ->
        Phoenix.PubSub.broadcast(
          Reviews.PubSub,
          "review:#{review.slug}",
          {:patchset_pushed, patchset.number}
        )

        {:ok, patchset}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  def list_patchsets(%Review{id: review_id}) do
    Repo.all(from p in Patchset, where: p.review_id == ^review_id, order_by: [asc: p.number])
  end

  def get_patchset!(id), do: Repo.get!(Patchset, id)

  def latest_patchset(%Review{id: review_id}) do
    Repo.one(
      from p in Patchset,
        where: p.review_id == ^review_id,
        order_by: [desc: p.number],
        limit: 1
    )
  end

  def latest_patchset_id(%Review{} = review) do
    case latest_patchset(review) do
      %Patchset{id: id} -> id
      nil -> nil
    end
  end

  def latest_patchset_number(%Review{} = review) do
    case latest_patchset(review) do
      %Patchset{number: number} -> number
      nil -> 1
    end
  end

  def list_files(%Patchset{id: patchset_id}) do
    Repo.all(from f in File, where: f.patchset_id == ^patchset_id, order_by: [asc: f.path])
  end

  defp next_patchset_number(review_id) do
    (Repo.one(from p in Patchset, where: p.review_id == ^review_id, select: max(p.number)) || 0) +
      1
  end

  defp generate_slug do
    :crypto.strong_rand_bytes(@slug_bytes * 2)
    |> Base.url_encode64(padding: false)
    |> String.replace(~r/[^A-Za-z0-9]/, "")
    |> String.slice(0, 8)
  end

  # --- Diff parsing -------------------------------------------------------

  @doc """
  Returns a list of `%{path, old_path, status, additions, deletions}` parsed
  out of a unified `git diff` string. Exposed for the LiveView so it can
  display +/- counts without re-querying the DB rows. Pure function.
  """
  @spec parse_diff_files(String.t() | nil) :: [map()]
  def parse_diff_files(nil), do: []
  def parse_diff_files(""), do: []

  def parse_diff_files(raw_diff) when is_binary(raw_diff) do
    # Split on `diff --git ` boundaries, keeping each chunk.
    raw_diff
    |> String.split(~r/^diff --git /m, trim: true)
    |> Enum.map(&parse_one_file_chunk/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_one_file_chunk(chunk) do
    lines = String.split(chunk, "\n")
    header_line = List.first(lines) || ""

    # Header looks like:  a/lib/foo.ex b/lib/foo.ex
    {old_path, new_path} =
      case Regex.run(~r|^a/(.+?) b/(.+)$|, header_line) do
        [_, o, n] -> {o, n}
        _ -> {nil, nil}
      end

    cond do
      is_nil(new_path) ->
        nil

      true ->
        status = detect_status(chunk, old_path, new_path)
        {additions, deletions} = count_hunk_changes(lines)
        path = if status == "deleted", do: old_path, else: new_path

        %{
          path: path,
          old_path: if(status in ["renamed", "deleted"], do: old_path),
          status: status,
          additions: additions,
          deletions: deletions
        }
    end
  end

  defp detect_status(chunk, old_path, new_path) do
    cond do
      String.contains?(chunk, "\nnew file mode") -> "added"
      String.contains?(chunk, "\ndeleted file mode") -> "deleted"
      old_path != new_path -> "renamed"
      true -> "modified"
    end
  end

  defp count_hunk_changes(lines) do
    Enum.reduce(lines, {0, 0}, fn line, {adds, dels} ->
      cond do
        String.starts_with?(line, "+++") -> {adds, dels}
        String.starts_with?(line, "---") -> {adds, dels}
        String.starts_with?(line, "+") -> {adds + 1, dels}
        String.starts_with?(line, "-") -> {adds, dels + 1}
        true -> {adds, dels}
      end
    end)
  end

  defp insert_files_for_patchset(%Patchset{id: patchset_id}, raw_diff) do
    files =
      raw_diff
      |> parse_diff_files()
      |> Enum.map(fn meta ->
        attrs = %{
          patchset_id: patchset_id,
          path: meta.path,
          old_path: meta.old_path,
          status: meta.status
        }

        case %File{} |> File.changeset(attrs) |> Repo.insert() do
          {:ok, file} -> {:ok, file}
          {:error, changeset} -> {:halt, changeset}
        end
      end)

    case Enum.find(files, &match?({:halt, _}, &1)) do
      {:halt, changeset} -> {:error, changeset}
      nil -> {:ok, Enum.map(files, fn {:ok, f} -> f end)}
    end
  end

  @doc """
  Returns the raw chunk for a single file inside a patchset (the substring
  between two `diff --git` markers). Used by the LiveView to pass per-file
  diff payloads to the React island so each file mounts independently.
  """
  @spec raw_diff_for_file(Patchset.t(), String.t()) :: String.t() | nil
  def raw_diff_for_file(%Patchset{raw_diff: nil}, _path), do: nil
  def raw_diff_for_file(%Patchset{raw_diff: ""}, _path), do: nil

  def raw_diff_for_file(%Patchset{raw_diff: raw_diff}, path) when is_binary(path) do
    # Re-split, prepend "diff --git " back onto each chunk, and find the
    # chunk whose header references this path.
    chunks = String.split(raw_diff, ~r/^diff --git /m, trim: true)

    Enum.find_value(chunks, fn chunk ->
      header = chunk |> String.split("\n", parts: 2) |> List.first()

      cond do
        is_nil(header) -> nil
        String.contains?(header, " b/" <> path) -> "diff --git " <> chunk
        String.contains?(header, "a/" <> path <> " ") -> "diff --git " <> chunk
        true -> nil
      end
    end)
  end
end
