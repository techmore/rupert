# frozen_string_literal: true

class ReconcileController < AuthenticatedController
  before_action :authorize_read, only: :index
  before_action :authorize_write, only: [:policy, :apply]

  def index
    @rows = Reconciler.build_rows
    @summary = Reconciler.summary(@rows)
    @size_groups = size_family_groups
    @push_guard = PlatformPushGuard.status_all.index_by { |s| s[:platform] }
  end

  def policy
    sku = params[:sku].to_s
    priority = params[:priority].to_s
    unless Reconciler::PRIORITIES.include?(priority)
      return redirect_to(reconcile_index_path, alert: "Unknown priority")
    end

    InventoryPolicy.set!(sku, priority) if sku.present?
    redirect_to(reconcile_index_path, notice: "Priority updated for #{sku}")
  end

  def apply
    @result = PlanApplier.apply!(skus: params[:skus].presence)
    redirect_to(reconcile_index_path, notice: "Applied #{@result[:applied]} adjustment(s)")
  rescue PlanApplier::SafetyLocked, StandardError => e
    redirect_to(reconcile_index_path, alert: e.message)
  end

  private

  # Each size family rendered as its root plus the sizes that derive from it,
  # so the screen shows which SKUs are derivatives of which root.
  def size_family_groups
    SizeFamily.includes(:members).order(:name).map do |family|
      root = family.base_grams&.to_f
      pending = family.size_changes.pending.index_by { |change| change.sku.downcase }
      members = family.members.order(:grams).map do |member|
        {
          member: member,
          current: member.square_variation_id ? InventoryLevel.total_for_variation(member.square_variation_id) : nil,
          target: root ? (root / member.grams.to_f).floor : nil,
          pending: pending[member.sku.downcase],
        }
      end
      root_item = nil
      if family.root_sku.present?
        variation = SquareVariation.find_by(sku: family.root_sku)
        root_item = {
          sku: family.root_sku,
          current: variation ? InventoryLevel.total_for_variation(variation.id) : nil,
        }
      end
      {
        family: family,
        root: root,
        root_item: root_item,
        members: members,
        pending_count: family.size_changes.pending.count,
      }
    end
  end

  def authorize_read
    authorize(:module, :reconcile_read?)
  end

  def authorize_write
    authorize(:module, :reconcile_write?)
  end
end
