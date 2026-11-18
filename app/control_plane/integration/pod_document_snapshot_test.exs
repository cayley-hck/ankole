defmodule Ankole.Pod.DocumentSnapshotTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false
  alias Ankole.Pod.{Documents, Pages}

  setup do
    Ankole.E2E.Harness.cleanup_committed_fixtures_on_exit!()
    owner = Ankole.PrincipalsFixtures.human_fixture().principal
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{})

    {:ok, %{page: page}} =
      Documents.write(
        Ankole.PrincipalsFixtures.actor_fixture(owner.uid),
        page.id,
        0,
        "<page><p>Before</p></page>"
      )

    %{owner: owner.uid, page: page}
  end

  test "a document snapshot holds its revision stable until the body has been read", ctx do
    {:ok, detail} =
      read_while_writer_attempts(
        ctx,
        "pages",
        fn -> Pages.get(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), ctx.page.id) end,
        &assert_write_waits_for_reader/1
      )

    assert detail.page.revision == 1
    assert detail.content.content == "<page><p>Before</p></page>"
    assert_write_commits(ctx)
  end

  # Replay is a lock-free read in one REPEATABLE READ snapshot, so a concurrent
  # writer commits without waiting and the replay still reports the snapshot.
  test "replay holds its revision and byte budget stable until all batches have been read", ctx do
    {:ok, replay} =
      read_while_writer_attempts(
        ctx,
        "page_changes",
        fn ->
          Documents.since(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), ctx.page.id, 0)
        end,
        &assert_write_commits/1
      )

    assert replay.revision == 1
    assert Enum.map(replay.changes, & &1.revision) == [1]
    refute replay.reset_required
  end

  defp read_while_writer_attempts(ctx, source, read, write) do
    observer = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if Process.get(handler) == :wait and metadata[:source] == source do
            Process.delete(handler)
            send(observer, {:read_paused, self()})

            receive do
              :continue_read -> :ok
            after
              5_000 -> raise "snapshot read was not released"
            end
          end
        end,
        nil
      )

    reader =
      Task.async(fn ->
        Repo.with_tenant(ctx.tenant.id, fn ->
          Process.put(handler, :wait)
          read.()
        end)
      end)

    try do
      assert_receive {:read_paused, reader_pid}, 2_000
      write.(ctx)
      send(reader_pid, :continue_read)
      Task.await(reader, 5_000)
    after
      send(reader.pid, :continue_read)
      :telemetry.detach(handler)
    end
  end

  defp assert_write_waits_for_reader(ctx) do
    # The test sets the lock timeout, so it owns the transaction and runs the
    # write body. AshPostgres gives `lock_not_available` as `Unavailable`.
    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Invalid.Unavailable{} = error]}} =
             Repo.transact(fn repo ->
               repo.query!("SET LOCAL lock_timeout = '100ms'")
               xml = "<page><p>After</p></page>"

               Documents.write_in_tx(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
                 ctx.page.id,
                 1,
                 Ankole.Kernel.page_validate(xml)
               )
             end)

    assert error.reason =~ "lock timeout"
  end

  defp assert_write_commits(ctx) do
    assert {:ok, %{page: %{revision: 2}}} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               ctx.page.id,
               1,
               "<page><p>After</p></page>"
             )
  end
end
