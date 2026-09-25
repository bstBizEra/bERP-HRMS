import router from "@/router"
import { createResource } from "frappe-ui"

export const userResource = createResource({
	url: "berp_hrms.api.get_current_user_info",
	cache: "berp_hrms:user",
	onError(error) {
		if (error && error.exc_type === "AuthenticationError") {
			router.push({ name: "Login" })
		}
	},
})
