import { createResource } from "frappe-ui"
import { employeeResource } from "./employee"
import { reactive } from "vue"

export const expenseClaimSummary = createResource({
	url: "berp_hrms.api.get_expense_claim_summary",
	auto: true,
	cache: "berp_hrms:expense_claim_summary",
})

const transformClaimData = (data) => {
	return data.map((claim) => {
		claim.doctype = "Expense Claim"
		return claim
	})
}

export const myClaims = createResource({
	url: "berp_hrms.api.get_expense_claims",
	params: {
		employee: employeeResource.data.name,
		limit: 10,
	},
	auto: true,
	cache: "berp_hrms:my_claims",
	transform(data) {
		return transformClaimData(data)
	},
	onSuccess() {
		expenseClaimSummary.reload()
	},
})

export const teamClaims = createResource({
	url: "berp_hrms.api.get_expense_claims",
	params: {
		employee: employeeResource.data.name,
		approver_id: employeeResource.data.user_id,
		for_approval: 1,
		limit: 10,
	},
	auto: true,
	cache: "berp_hrms:team_claims",
	transform(data) {
		return transformClaimData(data)
	},
})

export let claimTypesByID = reactive({})

export const claimTypesResource = createResource({
	url: "berp_hrms.api.get_expense_claim_types",
	auto: true,
	transform(data) {
		return data.map((row) => {
			claimTypesByID[row.name] = row
			return row
		})
	},
})
