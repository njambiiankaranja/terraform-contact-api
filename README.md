# Serverless Contact Form API with Terraform

![Terraform CI](https://github.com/njambiiankaranja/terraform-contact-api/actions/workflows/terraform-ci.yml/badge.svg)

A complete backend for a website contact or RSVP form, built on AWS and defined entirely as code with Terraform. A visitor submits the form, the data is validated and saved to a database, and you receive an email straight away. There are no servers to run, patch or pay for while nobody is using it.

---

## The Problem It Solves

Static websites (hosted on S3, GitHub Pages, Vercel and similar) are fast, cheap and secure, but they cannot process a form on their own. There is no server to receive the data. The usual options are a third-party form service, which means giving up control of your data and often paying a monthly fee, or running a server just to handle a few messages.

This project is a third option: a small serverless API that does exactly one job. It costs almost nothing when idle, scales automatically when busy, and you own the data and the code.

---

## What It Does

1. A visitor fills in the form on your website and submits it.
2. The browser sends the data to a public **API Gateway** endpoint (`POST /submit`).
3. API Gateway applies rate limiting and passes the request to a **Lambda** function.
4. The function checks the input: required fields, length limits, valid email format, and a hidden spam trap.
5. If the input is valid, the function saves it to **DynamoDB** and publishes a message to **SNS**.
6. SNS emails you the submission. The visitor receives a confirmation message.
7. If the function ever fails, a **CloudWatch alarm** emails you through the same topic.

---

## Advantages

- **No servers to manage.** Nothing to patch, restart or monitor. AWS runs the infrastructure.
- **Pay only for use.** API Gateway, Lambda, DynamoDB and SNS are all billed per request, so an idle form costs close to nothing.
- **Scales automatically.** The same setup handles one message a week or a sudden burst, without any changes.
- **You own your data.** Submissions are stored in your own DynamoDB table, not a third party's dashboard.
- **Secure by design.** The function has the narrowest permissions it needs, input is validated before it is stored, and requests are rate limited.
- **Reproducible.** The entire stack is Terraform code. It can be created with one command, rebuilt identically, and removed completely with another, which also makes it safe to experiment with.
- **Data expires automatically.** Each submission is deleted after a retention period (90 days by default), so personal data is not kept longer than needed.
- **Observable.** Logs are kept for 14 days and an alarm tells you when something breaks, so problems do not go unnoticed.
- **Reusable.** The same API can serve a contact form, an RSVP form, a newsletter sign-up or a feedback form on any number of sites.

---

## Architecture

```text
 Website form
     |  POST /submit (JSON)
     v
 Amazon API Gateway (HTTP API)
     |  rate limited, CORS enabled
     v
 AWS Lambda (Python 3.11)
     |  validates the input
     +------------------> Amazon DynamoDB  (stores the submission)
     |
     +------------------> Amazon SNS  ----> Email notification

 CloudWatch alarm on Lambda errors ----> same SNS topic
```

### Components

| Resource | Role |
|---|---|
| API Gateway HTTP API | Public `POST /submit` endpoint with CORS and request throttling (5 requests per second, bursts of 10) |
| Lambda function | Validates the request, writes to DynamoDB and publishes to SNS. Python 3.11, 10 second timeout |
| DynamoDB table | Stores each submission (`id`, `name`, `email`, `message`, `received_at`, `expires_at`). On-demand billing, with automatic expiry (TTL) |
| SNS topic and email subscription | Sends you an email for every submission |
| CloudWatch alarm | Emails you through the same topic if the function reports an error |
| CloudWatch log group | Lambda logs, kept for 14 days |
| IAM role | Gives the function only what it needs (see below) |

---

## Security and Safeguards

- **Least-privilege IAM.** The function can write to this one table (`dynamodb:PutItem`) and publish to this one topic (`sns:Publish`), plus write its own logs. Nothing else in the account is reachable.
- **Input validation.** `name`, `email` and `message` are required, limited to 100, 200 and 2,000 characters, and the email format is checked. Bad requests get a clear `400` response and are never stored.
- **Spam trap.** A hidden `website` field that real visitors never fill in. Many bots fill every field, and submissions that include it are quietly ignored.
- **Rate limiting.** The API stage throttles requests, so a script cannot flood your inbox or your table.
- **CORS control.** The `allowed_origins` variable decides which websites may call the API from a browser.

---

## Design Decisions

| Choice | Why |
|---|---|
| HTTP API instead of REST API | Simpler and cheaper, with built-in CORS, and it has everything this project needs |
| DynamoDB | Fits a simple "save a record" workload, needs no capacity planning, and costs nothing when idle |
| SNS email notifications | The quickest way to get a message in your inbox with no extra setup, and the same topic carries the error alarms |
| 10 second Lambda timeout | The function does two quick calls. A short timeout stops a stuck request from running up charges |
| Hidden spam-trap field | Catches simple bots with no CAPTCHA, so real visitors see nothing extra |
| Terraform for everything | The infrastructure is documented, reviewable and repeatable instead of a set of console clicks |

---

## Things to Know

Practical notes about how it behaves, so there are no surprises:

- **Confirm the email once.** After the first deploy, AWS sends a confirmation email to your notification address. Until you click **Confirm subscription**, no submission emails arrive. The data is still saved to DynamoDB in the meantime.
- **The endpoint is public by design.** A website form has to be callable by anyone. Validation, rate limiting and the spam trap block casual abuse, but they are not a CAPTCHA. A busy public site should add AWS WAF or a CAPTCHA.
- **Restrict CORS before going live.** `allowed_origins` defaults to `*` so testing is easy. Set it to your site's address so other sites cannot call your API from a browser.
- **Expect one email per submission.** That is perfect for a personal site, but a high-traffic form would be better served by a digest or a ticketing tool.
- **Emails are plain text.** SNS keeps things simple. Formatted messages or an automatic reply to the visitor would need Amazon SES.
- **The first request after a quiet period is slightly slower.** Lambda needs a moment to start the function (a cold start). Later requests are fast.
- **A rare failure can create a duplicate.** The function saves the record first and then sends the notification. If the notification step fails, the visitor sees an error and may resubmit, so the same message can appear twice. The alarm will tell you when this happens.
- **Submissions contain personal data.** Names and email addresses are kept for `retention_days` (90 by default) and then deleted automatically by DynamoDB. Deletion is not instant: expired items are usually removed within a day or two. Copy anything you need to keep elsewhere before it expires.
- **Validation errors do not trigger the alarm.** A visitor sending bad input gets a `400` response. The alarm is for real failures such as a database error.
- **Costs are tiny but not zero.** Everything is billed per use. Destroy the stack when you do not need it, and check current AWS pricing before leaving anything running long term.

---

## API

`POST /submit` with a JSON body:

```json
{
  "name": "Jane Doe",
  "email": "jane@example.com",
  "message": "Hello!"
}
```

| Status | Response |
|---|---|
| `200` | `{"message": "Thank you, your message was received"}` |
| `400` | `{"error": "message is required"}` (or another validation message) |

### Calling it from a web page

```html
<form id="contact-form">
  <input name="name" placeholder="Name" required>
  <input name="email" type="email" placeholder="Email" required>
  <textarea name="message" placeholder="Message" required></textarea>
  <!-- Spam trap: hide it with CSS, real visitors leave it empty -->
  <input name="website" style="display:none" tabindex="-1" autocomplete="off">
  <button type="submit">Send</button>
</form>

<script>
  document.getElementById("contact-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const data = Object.fromEntries(new FormData(e.target));
    const res = await fetch("YOUR_API_URL", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data),
    });
    alert((await res.json()).message || "Something went wrong");
  });
</script>
```

Replace `YOUR_API_URL` with the `api_url` output after deploying.

---

## Project Structure

```text
terraform-contact-api/
├── main.tf         # DynamoDB, SNS, IAM, Lambda, API Gateway, CloudWatch alarm
├── variables.tf    # Region, project name, notification email, allowed origins
├── outputs.tf      # API URL and table name
├── providers.tf    # Provider versions and S3 remote backend
├── .github/workflows/terraform-ci.yml   # Runs fmt and validate on every pull request
├── handler.py      # Lambda function code
└── README.md
```

### Variables

| Variable | Default | Description |
|---|---|---|
| `notification_email` | none, required | Address that receives a message for every submission |
| `allowed_origins` | `["*"]` | Websites allowed to call the API from a browser |
| `aws_region` | `us-east-1` | Region to deploy into |
| `project_name` | `contact-api` | Prefix for resource names and the `Project` tag |
| `retention_days` | `90` | Days to keep each submission before it is deleted automatically |

---

## Deployment

Prerequisites: an AWS account with the AWS CLI configured, Terraform `>= 1.0.0`, and an S3 bucket for remote state (set in `providers.tf`, and it must exist before `terraform init`).

Create a `terraform.tfvars` file (ignored by Git) with the email that should receive notifications:

```hcl
notification_email = "you@example.com"
```

Then deploy:

```bash
terraform init
terraform plan
terraform apply
```

Click **Confirm subscription** in the email AWS sends you.

### Try it

```bash
curl -X POST "$(terraform output -raw api_url)" \
  -H "Content-Type: application/json" \
  -d '{"name":"Test","email":"test@example.com","message":"Hello from curl"}'

aws dynamodb scan --table-name $(terraform output -raw table_name)
```

You should get a success message, an email, and a record in the table with an `expires_at` timestamp. Sending an empty `message` should return `{"error": "message is required"}`.

### Tear down

```bash
terraform destroy
```

---

## Ideas for Extending It

- Restrict `allowed_origins` to a real site and connect an actual form, such as a wedding RSVP page
- Send formatted emails and an automatic reply to the visitor with Amazon SES
- Add a CAPTCHA or AWS WAF for high-traffic public sites
- Put the API on a custom domain with an ACM certificate
- Extend the CI pipeline to run `terraform plan` using GitHub Actions OIDC, with no stored AWS keys
- Add a CloudWatch dashboard for requests, errors and latency