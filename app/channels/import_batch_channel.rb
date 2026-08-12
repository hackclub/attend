class ImportBatchChannel < ApplicationCable::Channel
  def subscribed
    import_batch = ImportBatch.find_by(id: params[:import_batch_id])

    if import_batch && current_user.can_access_event?(import_batch.event)
      stream_from "import_batch_#{import_batch.id}"
    else
      reject
    end
  end

  def unsubscribed
  end
end
